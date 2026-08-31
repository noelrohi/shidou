//! The desktop half of pairing a phone: which addresses this Mac is reachable
//! at, and the QR the phone scans to learn them.
//!
//! The phone cannot discover the daemon on its own — mDNS is deferred — so the
//! desktop tells it everything at once: a versioned `shidou://pair` URL
//! carrying the daemon's identity, its candidate addresses in priority order,
//! and the token. The phone saves the whole list and fails over between them
//! as it moves between Wi-Fi and its tailnet.
//!
//! Nothing here may run in a frame. Enumerating interfaces is a syscall and
//! encoding a QR is a few hundred microseconds of work; both belong on the
//! background executor, with the result cached on the entity.

use std::collections::HashSet;
use std::net::Ipv4Addr;
use std::sync::Arc;

use gpui::RenderImage;
use url::Url;

/// Pixels per QR module. The code renders at roughly twice its on-screen size
/// so it stays sharp on a Retina display, and a phone camera reads it from
/// across a desk.
const MODULE_PIXELS: u32 = 8;

/// The quiet zone the QR spec requires: four modules of blank on every side.
/// Without it, scanners hunt for the finder patterns and often give up.
const QUIET_MODULES: u32 = 4;

/// Everything the Daemon settings pane needs to draw the pairing block.
pub struct PairingCode {
    /// The `shidou://pair` URL encoded in the image, also useful to copy.
    pub url: String,
    /// The addresses in the payload, in the order the phone will try them.
    pub addresses: Vec<String>,
    pub image: Arc<RenderImage>,
}

/// Builds the payload and its QR. Returns `None` when this Mac has no
/// reachable address, or when the payload is too large to encode.
pub fn build(daemon_id: &str, hostname: &str, port: u16, token: &str) -> Option<PairingCode> {
    let addresses = candidate_addresses(hostname, port);
    if addresses.is_empty() || token.trim().is_empty() {
        return None;
    }
    let url = pairing_url(daemon_id, hostname, &addresses, token);
    let image = qr_image(&url)?;
    Some(PairingCode {
        url,
        addresses,
        image,
    })
}

/// The `shidou://pair?v=1&…` URL, parsed on the phone by `PairingPayload`.
///
/// Values are hostnames, dotted-quad addresses, and a hex token, so form and
/// percent encoding agree on every byte that can appear here.
pub fn pairing_url(daemon_id: &str, hostname: &str, addresses: &[String], token: &str) -> String {
    let mut url = Url::parse("shidou://pair").expect("static pairing URL parses");
    {
        let mut query = url.query_pairs_mut();
        query.append_pair("v", "1");
        query.append_pair("id", daemon_id);
        let name = display_name(hostname);
        if !name.is_empty() {
            query.append_pair("name", &name);
        }
        for address in addresses {
            query.append_pair("addr", address);
        }
        query.append_pair("token", token);
    }
    url.to_string()
}

/// Every address the phone should try, in the order it should try them.
///
/// LAN first because it is the fastest path and the common case, the `.local`
/// name next because it survives a DHCP lease change that moves the IP, and
/// the tailnet last: it works from anywhere, so it is the fallback rather
/// than the default. The phone reorders this list as it learns which address
/// actually answers.
pub fn candidate_addresses(hostname: &str, port: u16) -> Vec<String> {
    let tailnet = tailnet_identity();
    let mut lan = Vec::new();
    for ip in interface_addresses() {
        if is_cgnat(ip) {
            // Tailnet addresses are added below, by name. Anything else in
            // the range is a stale node record or another tunnel squatting
            // there, and would cost a connect attempt that routes nowhere.
            continue;
        }
        if ip.is_private() {
            lan.push(ip);
        }
    }
    let mut addresses: Vec<String> = lan.iter().map(|ip| format!("{ip}:{port}")).collect();
    if let Some(local) = local_name(hostname) {
        addresses.push(format!("{local}:{port}"));
    }
    addresses.extend(tailnet.candidates().map(|host| format!("{host}:{port}")));
    dedup_preserving_order(&mut addresses);
    addresses
}

/// Drops later repeats and keeps the first of each.
///
/// Priority order is the whole point of this list, so it cannot be sorted,
/// and `Vec::dedup` only collapses adjacent pairs — while a duplicate here is
/// precisely the non-adjacent kind: a second interface on the same subnet, or
/// a tailnet entry that repeats a LAN literal already listed above it.
fn dedup_preserving_order(addresses: &mut Vec<String>) {
    let mut seen = HashSet::new();
    addresses.retain(|address| seen.insert(address.clone()));
}

/// What Tailscale says this node is.
#[derive(Debug, Default)]
struct TailnetIdentity {
    /// The MagicDNS name, without its trailing dot.
    name: Option<String>,
    ips: Vec<Ipv4Addr>,
}

impl TailnetIdentity {
    /// The hosts to advertise, most useful first.
    ///
    /// The MagicDNS name leads because it is the only form an iOS client can
    /// actually dial: App Transport Security refuses cleartext to a
    /// `100.64.0.0/10` literal — that range is not among the private blocks
    /// `NSAllowsLocalNetworking` exempts — while a `*.ts.net` name is covered
    /// by the app's ATS exception for that domain. The raw IPs follow for
    /// clients with no such restriction, and only when there is no name.
    fn candidates(&self) -> impl Iterator<Item = String> + '_ {
        let name = self.name.clone();
        let ips = if name.is_some() {
            Vec::new()
        } else {
            self.ips.iter().map(|ip| ip.to_string()).collect()
        };
        name.into_iter().chain(ips)
    }
}

/// `100.64.0.0/10`, the range Tailscale assigns from. Membership is
/// necessary but not sufficient: other tunnels squat here too, which is why
/// candidates come from `tailnet_addresses` rather than this test.
fn is_cgnat(ip: Ipv4Addr) -> bool {
    let octets = ip.octets();
    octets[0] == 100 && (64..=127).contains(&octets[1])
}

/// This node's tailnet identity, straight from Tailscale.
///
/// The CGNAT range alone is not evidence: a Mac can hold two `utun`
/// interfaces inside `100.64.0.0/10` — a stale tailnet node record, another
/// tunnel squatting in the range — and only what the running daemon claims is
/// sure to route back here.
///
/// A subprocess is fine here and only here: this whole module runs on the
/// background executor. With no Tailscale CLI installed the identity is
/// empty, and pairing falls back to LAN candidates.
fn tailnet_identity() -> TailnetIdentity {
    const CLI_PATHS: [&str; 3] = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ];
    for path in CLI_PATHS {
        if !std::path::Path::new(path).exists() {
            continue;
        }
        let Ok(output) = std::process::Command::new(path)
            .args(["status", "--json"])
            .output()
        else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let Ok(status) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
            continue;
        };
        let this = &status["Self"];
        let name = this["DNSName"]
            .as_str()
            .map(|name| name.trim_end_matches('.').to_owned())
            .filter(|name| !name.is_empty());
        let ips: Vec<Ipv4Addr> = this["TailscaleIPs"]
            .as_array()
            .map(|values| {
                values
                    .iter()
                    .filter_map(|value| value.as_str()?.parse().ok())
                    .collect()
            })
            .unwrap_or_default();
        if name.is_some() || !ips.is_empty() {
            return TailnetIdentity { name, ips };
        }
    }
    TailnetIdentity::default()
}

/// The Bonjour name the phone can resolve on the same network. `gethostname`
/// already returns it with the suffix on most Macs; add it when it does not.
fn local_name(hostname: &str) -> Option<String> {
    let trimmed = hostname.trim().trim_end_matches('.');
    if trimmed.is_empty() || trimmed.contains(' ') {
        return None;
    }
    if trimmed.ends_with(".local") {
        return Some(trimmed.to_owned());
    }
    if trimmed.contains('.') {
        // Already a qualified name of some other kind; take it as given.
        return Some(trimmed.to_owned());
    }
    Some(format!("{trimmed}.local"))
}

/// What the phone shows for this Mac.
fn display_name(hostname: &str) -> String {
    hostname
        .trim()
        .trim_end_matches('.')
        .trim_end_matches(".local")
        .to_owned()
}

/// Up interfaces with an IPv4 address, minus loopback and link-local.
#[cfg(unix)]
fn interface_addresses() -> Vec<Ipv4Addr> {
    let mut found = Vec::new();
    unsafe {
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut list) != 0 {
            return found;
        }
        let mut cursor = list;
        while !cursor.is_null() {
            let entry = &*cursor;
            cursor = entry.ifa_next;
            if entry.ifa_addr.is_null() {
                continue;
            }
            if i32::from((*entry.ifa_addr).sa_family) != libc::AF_INET {
                continue;
            }
            if entry.ifa_flags & libc::IFF_UP as u32 == 0 {
                continue;
            }
            let address = &*(entry.ifa_addr as *const libc::sockaddr_in);
            let ip = Ipv4Addr::from(u32::from_be(address.sin_addr.s_addr));
            if ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() {
                continue;
            }
            if !found.contains(&ip) {
                found.push(ip);
            }
        }
        libc::freeifaddrs(list);
    }
    found
}

#[cfg(not(unix))]
fn interface_addresses() -> Vec<Ipv4Addr> {
    Vec::new()
}

/// Encodes `text` as a QR image GPUI can paint.
///
/// The buffer is built by hand rather than through an image encoder: the
/// pixels are one of two colours, so scaling is a nested loop and there is
/// nothing to decode on the other side.
fn qr_image(text: &str) -> Option<Arc<RenderImage>> {
    let (side, pixels) = qr_pixels(text)?;
    let buffer = image::RgbaImage::from_raw(side, side, pixels)?;
    Some(Arc::new(RenderImage::new(vec![image::Frame::new(buffer)])))
}

/// The square BGRA buffer behind the image, and its side in pixels.
fn qr_pixels(text: &str) -> Option<(u32, Vec<u8>)> {
    let code = qrcode::QrCode::new(text.as_bytes()).ok()?;
    let modules = code.to_colors();
    let width = code.width() as u32;
    let side = (width + QUIET_MODULES * 2) * MODULE_PIXELS;

    // BGRA, the packing `RenderImage` uploads as-is.
    let mut pixels = vec![255_u8; (side * side * 4) as usize];
    for (index, module) in modules.iter().enumerate() {
        if *module != qrcode::Color::Dark {
            continue;
        }
        let module_x = index as u32 % width + QUIET_MODULES;
        let module_y = index as u32 / width + QUIET_MODULES;
        for y in 0..MODULE_PIXELS {
            let row = (module_y * MODULE_PIXELS + y) * side;
            for x in 0..MODULE_PIXELS {
                let offset = ((row + module_x * MODULE_PIXELS + x) * 4) as usize;
                pixels[offset] = 0;
                pixels[offset + 1] = 0;
                pixels[offset + 2] = 0;
                pixels[offset + 3] = 255;
            }
        }
    }

    Some((side, pixels))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_url_lists_addresses_in_order() {
        let url = pairing_url(
            "daemon-1",
            "studio.local",
            &["192.168.1.20:34123".into(), "100.90.1.2:34123".into()],
            "abc123",
        );
        assert_eq!(
            url,
            "shidou://pair?v=1&id=daemon-1&name=studio&addr=192.168.1.20%3A34123&addr=100.90.1.2%3A34123&token=abc123"
        );
    }

    #[test]
    fn local_name_adds_the_suffix_only_when_missing() {
        assert_eq!(local_name("studio"), Some("studio.local".into()));
        assert_eq!(local_name("studio.local"), Some("studio.local".into()));
        assert_eq!(local_name("studio.local."), Some("studio.local".into()));
        assert_eq!(local_name(""), None);
    }

    #[test]
    fn tailnet_candidates_prefer_the_magic_dns_name() {
        let named = TailnetIdentity {
            name: Some("mac.tailf00679.ts.net".into()),
            ips: vec![Ipv4Addr::new(100, 92, 14, 103)],
        };
        assert_eq!(
            named.candidates().collect::<Vec<_>>(),
            vec!["mac.tailf00679.ts.net".to_owned()],
            "an iOS client cannot dial a CGNAT literal under ATS, so the name stands alone"
        );

        let unnamed = TailnetIdentity {
            name: None,
            ips: vec![Ipv4Addr::new(100, 92, 14, 103)],
        };
        assert_eq!(
            unnamed.candidates().collect::<Vec<_>>(),
            vec!["100.92.14.103".to_owned()]
        );

        assert_eq!(TailnetIdentity::default().candidates().count(), 0);
    }

    #[test]
    fn dedup_keeps_the_first_of_each_non_adjacent_repeat() {
        let mut addresses: Vec<String> = [
            "192.168.1.20:34123",
            "10.0.0.4:34123",
            "192.168.1.20:34123",
            "studio.local:34123",
            "10.0.0.4:34123",
        ]
        .iter()
        .map(|address| (*address).to_owned())
        .collect();
        dedup_preserving_order(&mut addresses);
        assert_eq!(
            addresses,
            vec![
                "192.168.1.20:34123".to_owned(),
                "10.0.0.4:34123".to_owned(),
                "studio.local:34123".to_owned(),
            ],
            "priority order survives, and Vec::dedup would have kept both repeats"
        );
    }

    #[test]
    fn cgnat_range_bounds() {
        assert!(is_cgnat(Ipv4Addr::new(100, 64, 0, 1)));
        assert!(is_cgnat(Ipv4Addr::new(100, 127, 255, 254)));
        assert!(!is_cgnat(Ipv4Addr::new(100, 63, 255, 255)));
        assert!(!is_cgnat(Ipv4Addr::new(100, 128, 0, 1)));
        assert!(!is_cgnat(Ipv4Addr::new(192, 168, 1, 20)));
    }

    #[test]
    fn an_empty_token_has_no_code() {
        // The daemon always has a token in practice; a blank one means the
        // settings file was hand-edited, and a QR that pairs to nothing is
        // worse than none.
        assert!(build("id", "studio", 34123, "   ").is_none());
    }

    #[test]
    fn qr_encodes_a_full_payload() {
        let url = pairing_url(
            "6E2F5C64-0000-4000-8000-000000000001",
            "rohis-macbook-pro.local",
            &[
                "192.168.1.20:34123".into(),
                "rohis-macbook-pro.local:34123".into(),
                "100.90.1.2:34123".into(),
            ],
            "0a1b2c3d4e5f60718293a4b5c6d7e8f9",
        );
        let image = qr_image(&url).expect("a pairing payload fits in a QR code");
        assert!(image.size(0).width.0 > 0);
    }
}

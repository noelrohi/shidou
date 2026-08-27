//! Binary payloads the demo can hand a client, all of them in memory.
//!
//! Two kinds live here. The workspace images are rendered once at startup from
//! [`crate::tree`]'s entries, so the visuals grid and any transcript image has
//! real bytes to show. Blobs a *client* stores — a pasted screenshot, say —
//! are kept in a small bounded map that dies with the process.
//!
//! Nothing in this module writes to disk. That is the demo's data posture, not
//! an implementation detail: the published policy says a message typed into
//! the demo reaches the operational log and nowhere else, and an attachment
//! spooled to a file would quietly widen that promise.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use parking_lot::Mutex;

use shidou_protocol::attachments::{ATTACHMENT_SCHEME, StoredAttachment};
use shidou_protocol::blob::SCHEME as BLOB_SCHEME;

use crate::png;
use crate::tree::{self, Content};

/// Client-stored blobs are a convenience, not a feature. The cap is generous
/// enough for a handful of screenshots and small enough that a public endpoint
/// cannot be turned into free storage.
const MAX_STORED_BLOBS: usize = 32;
const MAX_STORED_BYTES: usize = 16 * 1024 * 1024;

pub struct Blobs {
    /// Rendered once; every client sees byte-identical images.
    fixtures: HashMap<String, Fixture>,
    stored: Mutex<Stored>,
}

struct Fixture {
    reference: String,
    path: PathBuf,
    bytes: Vec<u8>,
}

#[derive(Default)]
struct Stored {
    /// Insertion-ordered so the oldest blob is the one evicted.
    order: Vec<String>,
    blobs: HashMap<String, Vec<u8>>,
    bytes: usize,
}

impl Default for Blobs {
    fn default() -> Self {
        Self::new()
    }
}

impl Blobs {
    pub fn new() -> Self {
        let fixtures = tree::images()
            .filter_map(|(relative_path, content)| {
                let Content::Image { width, height, hue } = content else {
                    return None;
                };
                let path = Path::new(tree::WORKSPACE_ROOT).join(relative_path);
                Some((
                    relative_path.to_owned(),
                    Fixture {
                        reference: format!(
                            "{ATTACHMENT_SCHEME}{:016x}",
                            digest(relative_path.as_bytes())
                        ),
                        bytes: png::encode_rgba(width, height, &chart(width, height, hue)),
                        path,
                    },
                ))
            })
            .collect();
        Self {
            fixtures,
            stored: Mutex::new(Stored::default()),
        }
    }

    /// The attachment record for a demo-workspace path, or `None` when the
    /// path is not one of the workspace's images.
    pub fn attachment(&self, path: &Path) -> Option<StoredAttachment> {
        let fixture = self
            .fixtures
            .values()
            .find(|fixture| fixture.path == path)?;
        Some(StoredAttachment {
            reference: fixture.reference.clone(),
            path: fixture.path.clone(),
            name: path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default()
                .to_owned(),
            is_dir: false,
        })
    }

    pub fn read(&self, reference: &str) -> Option<Vec<u8>> {
        if let Some(fixture) = self
            .fixtures
            .values()
            .find(|fixture| fixture.reference == reference)
        {
            return Some(fixture.bytes.clone());
        }
        self.stored.lock().blobs.get(reference).cloned()
    }

    /// Accepts a client-supplied blob and returns the reference and the path
    /// the daemon *would* have written it to. The path is synthetic: nothing
    /// is created, and only [`Self::read`] can retrieve the bytes.
    pub fn store(&self, mime_type: &str, bytes: Vec<u8>) -> anyhow::Result<(String, PathBuf)> {
        if bytes.len() > MAX_STORED_BYTES {
            anyhow::bail!("the Shidou demo accepts blobs up to {MAX_STORED_BYTES} bytes");
        }
        let extension = mime_type
            .rsplit_once('/')
            .map(|(_, subtype)| subtype)
            .filter(|subtype| subtype.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or("bin");
        let reference = format!("{BLOB_SCHEME}{:016x}.{extension}", digest(&bytes));
        let path = Path::new(tree::HOME)
            .join(".shidou/blobs")
            .join(reference.trim_start_matches(BLOB_SCHEME));

        let mut stored = self.stored.lock();
        if !stored.blobs.contains_key(&reference) {
            stored.bytes += bytes.len();
            stored.order.push(reference.clone());
            stored.blobs.insert(reference.clone(), bytes);
            while stored.order.len() > MAX_STORED_BLOBS || stored.bytes > MAX_STORED_BYTES {
                let oldest = stored.order.remove(0);
                if let Some(evicted) = stored.blobs.remove(&oldest) {
                    stored.bytes -= evicted.len();
                }
            }
        }
        Ok((reference, path))
    }
}

/// FNV-1a. The reference only has to be stable and collision-resistant enough
/// to name a handful of fixtures, so this avoids pulling in a hash crate.
fn digest(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for &byte in bytes {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Draws a bar chart. `hue` picks the series colour, and also seeds the bar
/// heights, so "before" and "after" read as two measurements of one thing.
fn chart(width: u32, height: u32, hue: u32) -> Vec<u8> {
    const BARS: u32 = 12;
    let mut pixels = vec![0_u8; width as usize * height as usize * 4];
    let (red, green, blue) = from_hue(hue);
    let mut heights = [0_u32; BARS as usize];
    let mut state = u64::from(hue).wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1;
    for slot in &mut heights {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        // Between a fifth and nine tenths of the plot area.
        *slot = height / 5 + (state % u64::from(height * 7 / 10)) as u32;
    }

    let gutter = width / (BARS * 2 + 1);
    for y in 0..height {
        for x in 0..width {
            let index = (y as usize * width as usize + x as usize) * 4;
            // A flat slate background, one baseline rule, and the bars.
            let bar = (x / gutter).checked_sub(1).map(|slot| slot / 2);
            let inside_bar = x / gutter >= 1
                && (x / gutter - 1).is_multiple_of(2)
                && bar.is_some_and(|bar| bar < BARS && height - y <= heights[bar as usize]);
            let baseline = height - y <= 2;
            let (r, g, b) = if inside_bar {
                (red, green, blue)
            } else if baseline {
                (0x3a, 0x40, 0x4a)
            } else {
                (0x14, 0x18, 0x1d)
            };
            pixels[index] = r;
            pixels[index + 1] = g;
            pixels[index + 2] = b;
            pixels[index + 3] = 0xff;
        }
    }
    pixels
}

/// A fully saturated colour at `hue` degrees, in the mid-value range that
/// stays legible against the chart's dark background in either theme.
fn from_hue(hue: u32) -> (u8, u8, u8) {
    let sector = (hue % 360) / 60;
    let offset = ((hue % 360) % 60) as f32 / 60.0;
    let (high, low) = (0xe6_u8 as f32, 0x3c_u8 as f32);
    let rising = (low + (high - low) * offset) as u8;
    let falling = (high - (high - low) * offset) as u8;
    let (high, low) = (high as u8, low as u8);
    match sector {
        0 => (high, rising, low),
        1 => (falling, high, low),
        2 => (low, high, rising),
        3 => (low, falling, high),
        4 => (rising, low, high),
        _ => (high, low, falling),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_images_render_once_and_read_back_as_png() {
        let blobs = Blobs::new();
        let path = Path::new(tree::WORKSPACE_ROOT).join("assets/latency-after.png");
        let attachment = blobs
            .attachment(&path)
            .expect("the fixture image is missing");

        assert_eq!(attachment.name, "latency-after.png");
        assert!(!attachment.is_dir);
        assert!(attachment.reference.starts_with(ATTACHMENT_SCHEME));
        let bytes = blobs.read(&attachment.reference).unwrap();
        assert_eq!(&bytes[1..4], b"PNG");
    }

    #[test]
    fn two_daemons_serve_byte_identical_images() {
        let path = Path::new(tree::WORKSPACE_ROOT).join("assets/latency-before.png");
        let first = Blobs::new();
        let second = Blobs::new();

        let reference = first.attachment(&path).unwrap().reference;
        assert_eq!(reference, second.attachment(&path).unwrap().reference);
        assert_eq!(first.read(&reference), second.read(&reference));
    }

    #[test]
    fn a_path_outside_the_workspace_has_no_attachment() {
        assert!(Blobs::new().attachment(Path::new("/etc/passwd")).is_none());
    }

    #[test]
    fn stored_blobs_round_trip_and_never_name_a_real_file() {
        let blobs = Blobs::new();
        let (reference, path) = blobs.store("image/png", vec![1, 2, 3]).unwrap();

        assert_eq!(blobs.read(&reference), Some(vec![1, 2, 3]));
        assert!(reference.starts_with(BLOB_SCHEME));
        assert!(reference.ends_with(".png"));
        assert!(!path.exists(), "the demo must not create files");
    }

    #[test]
    fn the_stored_blob_map_evicts_rather_than_growing_without_bound() {
        let blobs = Blobs::new();
        let first = blobs.store("image/png", vec![0]).unwrap().0;
        for value in 1..=MAX_STORED_BLOBS {
            blobs.store("image/png", vec![value as u8]).unwrap();
        }

        assert!(blobs.read(&first).is_none());
        assert_eq!(blobs.stored.lock().order.len(), MAX_STORED_BLOBS);
    }

    #[test]
    fn an_oversized_blob_is_refused_instead_of_buffered() {
        assert!(
            Blobs::new()
                .store("image/png", vec![0; MAX_STORED_BYTES + 1])
                .is_err()
        );
    }
}

//! Entry point for the Demo Daemon.
//!
//! Deployment is Caddy terminating TLS in front of this process, which binds
//! loopback and speaks plain WebSocket — `shidou_core::serve` has no TLS
//! server of its own. Caddy also owns rate limiting and the access log that
//! carries the requester's IP; see [`shidou_demo::log`] for why the two logs
//! are separate halves of one published promise.

use std::net::{SocketAddr, TcpListener};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use anyhow::{Context as _, anyhow, bail};
use shidou_demo::{DEFAULT_TOKEN, DemoBackend, log};
use shidou_protocol::{DAEMON_TOKEN_ENV, DaemonReady, PROTOCOL_VERSION};

const DEFAULT_BIND: &str = "127.0.0.1:8787";

fn main() -> anyhow::Result<()> {
    let arguments = Arguments::parse(std::env::args().skip(1))?;
    let token = std::env::var(DAEMON_TOKEN_ENV).unwrap_or_else(|_| DEFAULT_TOKEN.to_owned());
    // The demo's token is public, but the process still has no reason to leave
    // it in an environment it might one day pass on.
    unsafe { std::env::remove_var(DAEMON_TOKEN_ENV) };

    let listener = TcpListener::bind(&arguments.bind).with_context(|| {
        format!(
            "could not bind the Shidou demo daemon to {}",
            arguments.bind
        )
    })?;
    let address = listener.local_addr()?;
    ensure_bind_allowed(address, arguments.allow_non_loopback)?;

    // Structured on stdout for whatever launched the process; the operational
    // log is stderr, so the two never interleave.
    println!(
        "{}",
        serde_json::to_string(&DaemonReady {
            address: address.to_string(),
            protocol_version: PROTOCOL_VERSION,
            pid: std::process::id(),
        })?
    );
    log::record(log::Record::Listening {
        address: &address.to_string(),
    });

    shidou_core::serve(
        listener,
        token,
        Arc::new(DemoBackend::new()),
        Arc::new(AtomicBool::new(false)),
        shidou_core::ServerOptions {
            allowed_origins: arguments.allowed_origins.into_iter().collect(),
            // No client may stop the public demo. A daemon that a reviewer can
            // shut down is a 2.1 rejection waiting to happen.
            allow_shutdown: false,
        },
    )
}

/// The demo's token is published, so a non-loopback bind puts an unauthenticated
/// endpoint straight onto the network. That is fine behind a TLS proxy and
/// nowhere else, so it takes an explicit flag.
fn ensure_bind_allowed(address: SocketAddr, allow_non_loopback: bool) -> anyhow::Result<()> {
    if address.ip().is_loopback() || allow_non_loopback {
        return Ok(());
    }
    bail!(
        "refusing non-loopback demo bind {address}; pass --allow-non-loopback only behind a TLS-terminating proxy"
    )
}

struct Arguments {
    bind: String,
    allowed_origins: Vec<String>,
    allow_non_loopback: bool,
}

impl Arguments {
    fn parse(arguments: impl IntoIterator<Item = String>) -> anyhow::Result<Self> {
        let mut bind = DEFAULT_BIND.to_owned();
        let mut allowed_origins = Vec::new();
        let mut allow_non_loopback = false;
        let mut arguments = arguments.into_iter();
        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--bind" => {
                    bind = arguments
                        .next()
                        .ok_or_else(|| anyhow!("--bind requires an address"))?;
                }
                "--allow-origin" => {
                    allowed_origins.push(
                        arguments
                            .next()
                            .filter(|origin| !origin.trim().is_empty())
                            .ok_or_else(|| anyhow!("--allow-origin requires an origin"))?,
                    );
                }
                "--allow-non-loopback" => allow_non_loopback = true,
                "--help" | "-h" => {
                    println!(
                        "usage: {} [--bind ADDRESS] [--allow-non-loopback] [--allow-origin ORIGIN]...\n\n\
                         Serves Shidou's scripted Demo Session. Nothing in it executes.\n\
                         The bearer token comes from {DAEMON_TOKEN_ENV}, or defaults to the\n\
                         published demo token.",
                        env!("CARGO_BIN_NAME")
                    );
                    std::process::exit(0);
                }
                unknown => bail!("unknown argument {unknown:?}"),
            }
        }
        Ok(Self {
            bind,
            allowed_origins,
            allow_non_loopback,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_public_endpoint_requires_an_explicit_opt_in() {
        assert!(ensure_bind_allowed("127.0.0.1:8787".parse().unwrap(), false).is_ok());
        assert!(ensure_bind_allowed("[::1]:8787".parse().unwrap(), false).is_ok());
        assert!(ensure_bind_allowed("0.0.0.0:8787".parse().unwrap(), false).is_err());
        assert!(ensure_bind_allowed("0.0.0.0:8787".parse().unwrap(), true).is_ok());
    }

    #[test]
    fn arguments_default_to_a_loopback_bind_with_no_browser_origins() {
        let arguments = Arguments::parse([]).unwrap();

        assert_eq!(arguments.bind, DEFAULT_BIND);
        assert!(arguments.allowed_origins.is_empty());
        assert!(!arguments.allow_non_loopback);
    }

    #[test]
    fn arguments_carry_repeated_origins_and_the_non_loopback_opt_in() {
        let arguments = Arguments::parse([
            "--bind".into(),
            "0.0.0.0:9000".into(),
            "--allow-non-loopback".into(),
            "--allow-origin".into(),
            "https://demo.shidou.dev".into(),
            "--allow-origin".into(),
            "http://localhost:3000".into(),
        ])
        .unwrap();

        assert_eq!(arguments.bind, "0.0.0.0:9000");
        assert!(arguments.allow_non_loopback);
        assert_eq!(
            arguments.allowed_origins,
            ["https://demo.shidou.dev", "http://localhost:3000"]
        );
    }

    #[test]
    fn an_unknown_argument_fails_rather_than_being_ignored() {
        assert!(Arguments::parse(["--demo-mode".into()]).is_err());
        assert!(Arguments::parse(["--bind".into()]).is_err());
    }
}

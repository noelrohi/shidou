//! Durable references for daemon-owned binary task payloads.

/// Scheme for a stored blob reference, e.g. `shidou-blob:3f2a...c1.png`.
pub const SCHEME: &str = "shidou-blob:";

pub fn is_reference(value: &str) -> bool {
    value.starts_with(SCHEME)
}

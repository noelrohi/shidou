//! The Demo Daemon: a fixture daemon serving Shidou's scripted Demo Session.
//!
//! This is a separate binary from `shidou-daemon` on purpose. The daemon users
//! run owns provider processes, credentials and a database, and must carry no
//! demo code path at all; this one owns none of those and executes nothing.
//! Its token is baked into the app and is therefore public, which is safe only
//! because there is nothing behind it to abuse.
//!
//! What it serves:
//!
//! * [`sessions`] — the projects and tasks, including the Demo Session and a
//!   Waiting Session for the list to mark.
//! * [`script`] — the scripted turn: streaming text and reasoning, a tool call
//!   with its result, a permission request, a unified diff, a multi-question
//!   form, and background work.
//! * [`tree`] — the workspace behind that diff: a file tree, readable files,
//!   branch and commit state, and the review diff itself.
//! * [`catalog`] — settings, the skills catalog, usage history and plan meters.
//! * [`blobs`] — images, rendered in memory so the visuals surface has real
//!   bytes to show.
//!
//! Data posture is [`log`]'s responsibility, and it is narrow by construction:
//! a message typed into the demo reaches the operational log and nowhere else.

pub mod backend;
pub mod blobs;
pub mod catalog;
pub mod log;
mod png;
pub mod script;
pub mod sessions;
pub mod tree;

pub use backend::DemoBackend;

/// The token the Demo Daemon accepts when the environment names no other.
///
/// This is public by construction: the app bakes it in so "Try the demo" is
/// one tap with nothing to type, which means anyone can read it out of the
/// binary. That is acceptable here and only here — the backend is a fixture
/// with no side effects, so the token grants nothing but bandwidth, and rate
/// limiting at the reverse proxy is what bounds that.
///
/// Never reuse this pattern for `shidou-daemon`.
pub const DEFAULT_TOKEN: &str = "shidou-demo";

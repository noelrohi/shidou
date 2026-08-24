//! Shared application identity used by the daemon and desktop client.

#[cfg(debug_assertions)]
pub const APP_NAME: &str = "Shidou Debug";
#[cfg(not(debug_assertions))]
pub const APP_NAME: &str = "Shidou";

#[cfg(debug_assertions)]
pub const APP_ID: &str = "dev.shidou.debug";
#[cfg(not(debug_assertions))]
pub const APP_ID: &str = "dev.shidou";

#[cfg(debug_assertions)]
pub const DATA_DIRECTORY_NAME: &str = "Shidou Debug";
#[cfg(not(debug_assertions))]
pub const DATA_DIRECTORY_NAME: &str = "Shidou";

//! Shared application identity used by the daemon and desktop client.

#[cfg(debug_assertions)]
pub const APP_NAME: &str = "Pagesmith Debug";
#[cfg(not(debug_assertions))]
pub const APP_NAME: &str = "Pagesmith";

#[cfg(debug_assertions)]
pub const APP_ID: &str = "dev.pagesmith.debug";
#[cfg(not(debug_assertions))]
pub const APP_ID: &str = "dev.pagesmith";

#[cfg(debug_assertions)]
pub const DATA_DIRECTORY_NAME: &str = "Pagesmith Debug";
#[cfg(not(debug_assertions))]
pub const DATA_DIRECTORY_NAME: &str = "Pagesmith";

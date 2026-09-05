use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use ts_rs::TS;

use crate::computer_use::ComputerAppGrant;
use crate::model::ProviderKind;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize, TS)]
#[serde(default)]
pub struct DaemonSettings {
    /// Allow agents to create Child Tasks. Existing children remain available.
    pub subtasks_enabled: bool,
    pub computer_use_enabled: bool,
    pub computer_use_allowed_apps: Vec<ComputerAppGrant>,
    /// Ask one-shot commit-message generation for Conventional Commit subjects.
    pub conventional_commit_messages: bool,
    pub disabled_providers: Vec<ProviderKind>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub provider_binary_overrides: HashMap<ProviderKind, String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Default for DaemonSettings {
    fn default() -> Self {
        Self {
            subtasks_enabled: true,
            computer_use_enabled: false,
            computer_use_allowed_apps: Vec::new(),
            conventional_commit_messages: false,
            disabled_providers: Vec::new(),
            provider_binary_overrides: HashMap::new(),
            extra: BTreeMap::new(),
        }
    }
}

impl DaemonSettings {
    pub fn default_path() -> PathBuf {
        dirs::home_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join(".shidou")
            .join("settings.json")
    }

    pub fn discard_legacy_app_keys(&mut self) {
        for key in ["analytics_enabled", "favorite_models", "theme", "language"] {
            self.extra.remove(key);
        }
    }
}

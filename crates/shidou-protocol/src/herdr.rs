//! Herdr resources exposed through the Shidou daemon.
//!
//! Herdr owns terminal workspaces and agent processes. These types preserve
//! that model instead of forcing a terminal-backed agent into `AgentSession`,
//! whose transcript and turn guarantees do not apply.

use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum HerdrAgentStatus {
    Idle,
    Working,
    Blocked,
    Done,
    #[default]
    Unknown,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct HerdrAgentSession {
    pub source: String,
    pub agent: String,
    pub kind: String,
    pub value: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct HerdrWorktree {
    pub repo_name: String,
    pub repo_root: String,
    pub checkout_path: String,
    pub is_linked_worktree: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct HerdrWorkspace {
    pub id: String,
    pub label: String,
    pub focused: bool,
    pub pane_count: usize,
    pub tab_count: usize,
    pub status: HerdrAgentStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<HerdrWorktree>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct HerdrAgent {
    /// Herdr's public pane id. Refresh it from each snapshot because moving a
    /// pane across workspaces can change this id.
    pub pane_id: String,
    /// Stable identity for the live terminal while its pane moves.
    pub terminal_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    pub agent: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    pub status: HerdrAgentStatus,
    pub focused: bool,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_session: Option<HerdrAgentSession>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct HerdrState {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<u32>,
    #[serde(default)]
    pub workspaces: Vec<HerdrWorkspace>,
    #[serde(default)]
    pub agents: Vec<HerdrAgent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unavailable_reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
pub struct HerdrAgentOutput {
    pub pane_id: String,
    pub text: String,
    pub revision: u64,
    pub truncated: bool,
}

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use ts_rs::TS;
use uuid::Uuid;

use crate::attachments::{AttachmentUpload, StoredAttachment};
use crate::computer_use::ComputerPermissions;
use crate::model::{AgentSession, Project, ProviderKind, ProviderProbe, UserInputAnswer};
use crate::persistence::{ComposerDraftChange, ComposerDrafts, SessionMessageMatch};
use crate::provider_session::{ProviderSessionFork, ProviderSessionForkRequest};
use crate::settings::DaemonSettings;
use crate::skills::SkillsCatalog;
use crate::usage::PlanUsage;
use crate::usage_history::{UsageHistory, UsageWindow};
use crate::workspace::{WorkspaceOperation, WorkspaceResult};

pub const PROTOCOL_VERSION: u32 = 6;
pub const MAX_WIRE_MESSAGE_BYTES: usize = 48 * 1024 * 1024;

// Shared presentation values used by both native and web gallery clients.
// The TypeScript binding generator exports these from the same source.
pub const VISUAL_IMAGE_EXTENSIONS: &[&str] = &["gif", "jpeg", "jpg", "png", "svg", "webp"];
pub const VISUAL_COMPACT_COLUMN_WIDTH: f32 = 112.0;
pub const VISUAL_LARGE_COLUMN_WIDTH: f32 = 210.0;
pub const VISUAL_GRID_HORIZONTAL_INSET: f32 = 16.0;

pub const DAEMON_TOKEN_ENV: &str = "SHIDOU_DAEMON_TOKEN";
pub const DAEMON_ADDRESS_ENV: &str = "SHIDOU_DAEMON_ADDRESS";
pub const APP_EXECUTABLE_ENV: &str = "SHIDOU_APP_EXECUTABLE";
/// Task Credential the daemon hands a provider process so the `shidou` CLI
/// inside it can reach back: a token scoped to that one Task.
pub const TASK_TOKEN_ENV: &str = "SHIDOU_TASK_TOKEN";
/// The Task a provider process belongs to, alongside [`TASK_TOKEN_ENV`].
pub const TASK_ID_ENV: &str = "SHIDOU_TASK_ID";

/// What a provider process needs to act as its Task's orchestrator: the
/// daemon's loopback address and a token that only reaches that root Task's
/// direct children. Minted per root runtime start and revoked when it ends.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct TaskCredential {
    pub address: String,
    pub token: String,
    pub task_id: Uuid,
}

/// The list-level view of a Task that an orchestrating agent reads: enough to
/// tell whether a child is still working, waiting on the user, or done, and
/// what it last said.
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct TaskSummary {
    pub id: Uuid,
    pub title: String,
    pub provider: ProviderKind,
    pub status: crate::model::SessionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_task_id: Option<Uuid>,
    /// Turns the Task has accepted so far, running or finished.
    pub turn_count: usize,
    /// Whether the newest turn has settled, whatever its outcome.
    pub last_turn_finished: bool,
    /// The final assistant message of the newest turn, once it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_assistant_message: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct DaemonReady {
    pub address: String,
    pub protocol_version: u32,
    pub pid: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ClientMessage {
    Hello {
        protocol_version: u32,
        token: String,
        client_id: Uuid,
        #[serde(default)]
        resume_from: Vec<ReplayCursor>,
    },
    Request(Request),
    Shutdown,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub request_id: Uuid,
    pub session_id: Uuid,
    pub runtime_id: Uuid,
    pub command: Command,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct ReplayCursor {
    pub session_id: Uuid,
    pub runtime_id: Uuid,
    /// Identifies the daemon process that assigned `sequence`.
    pub epoch: Uuid,
    pub sequence: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Command {
    /// Resolve the daemon-owned provider runtime for an existing task.
    ///
    /// Clients use this after reconnecting or opening the same daemon from a
    /// second app. It observes the session actor without starting, replacing,
    /// or otherwise mutating the provider process.
    AttachSession,
    Start {
        options: WireDriverStartOptions,
    },
    Prompt {
        prompt: String,
        submission_id: Uuid,
    },
    Steer {
        prompt: String,
    },
    Cancel,
    CancelComputerUse,
    RefreshBackgroundWork,
    StopBackgroundWork {
        key: Value,
        control_id: String,
    },
    Respond {
        request_id: String,
        option_id: String,
    },
    RespondUserInput {
        request_id: String,
        answers: Vec<UserInputAnswer>,
    },
    RunComputerTool {
        request: WireComputerToolRequest,
    },
    RejectComputerTool {
        request: WireComputerToolRequest,
        reason: String,
    },
    ApplyOptions {
        options: WireSessionOptions,
    },
    Compact {
        custom_instructions: Option<String>,
    },
    Rollback {
        turns: usize,
    },
    Fork {
        turns_to_remove: usize,
    },
    GetSettings,
    UpdateSettings {
        settings: DaemonSettings,
    },
    ProbeProvider {
        provider: ProviderKind,
        binary_override: Option<String>,
        discover_models: bool,
        probe_version: bool,
    },
    FetchPlanUsage {
        provider: ProviderKind,
        binary_override: Option<String>,
        cli_version: Option<String>,
    },
    ProbeComputerPermissions {
        prompt: bool,
    },
    LoadUsageHistory {
        window: UsageWindow,
        project_roots: Vec<PathBuf>,
    },
    LoadSkills {
        projects: Vec<(String, PathBuf)>,
    },
    SetSkillsEnabled {
        dirs: Vec<PathBuf>,
        enabled: bool,
    },
    TrashSkills {
        dirs: Vec<PathBuf>,
    },
    LoadTaskState,
    SaveTaskState {
        projects: Vec<Project>,
        live_session_ids: Vec<Uuid>,
        sessions: Vec<AgentSession>,
    },
    /// Explicitly remove one daemon-owned task. Ordinary state saves are
    /// merge-only so a stale client snapshot cannot delete tasks another
    /// client just created.
    RemoveSession,
    /// Remove one queued follow-up by identity. Queue deletions cannot travel
    /// in a merge-only task snapshot: omission might only mean the client is
    /// stale, so the daemon needs an explicit deletion command.
    RemoveQueuedMessage {
        message_id: Uuid,
    },
    /// Explicitly set or clear the archive mark on one daemon-owned task.
    /// Saves never carry the mark, so a stale client snapshot cannot clear a
    /// mark another client just set — only this can.
    /// Create a Task under `parent_task_id`, in the parent's project and
    /// workspace, and hand back the options its runtime should start with.
    /// The connection's Task Credential, when it has one, overrides the parent.
    CreateChildTask {
        parent_task_id: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        provider: Option<ProviderKind>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mode: Option<crate::model::RuntimeMode>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reasoning_effort: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        interaction_mode: Option<crate::model::InteractionMode>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    /// The models the daemon knows for a provider, so an orchestrating agent
    /// can pick one for a child. `None` means the provider of `session_id`.
    ListProviderModels {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        provider: Option<ProviderKind>,
    },
    /// The list-level state of one Task, addressed by `session_id`.
    ReadTaskSummary,
    /// Every Task whose parent is `session_id`.
    ListChildTasks,
    ArchiveSession {
        archived: bool,
    },
    /// Explicitly remove one daemon-owned project. Saves merge projects the
    /// same way they merge tasks, so dropping one from a client snapshot can
    /// never delete it — only this can.
    RemoveProject {
        project_id: Uuid,
    },
    HydrateSession {
        session_id: Uuid,
    },
    SearchSessionMessages {
        query: String,
        limit: usize,
    },
    LoadComposerDrafts,
    SaveComposerDrafts {
        drafts: ComposerDrafts,
        generation: u64,
    },
    ApplyComposerDraftChanges {
        changes: Vec<ComposerDraftChange>,
    },
    StoreBlob {
        mime_type: String,
        #[serde(with = "base64_bytes")]
        #[ts(type = "string")]
        bytes: Vec<u8>,
    },
    ImportAttachment {
        name: String,
        upload: AttachmentUpload,
    },
    ImportPathAttachment {
        #[ts(type = "string")]
        path: PathBuf,
    },
    /// Import many daemon-host paths in one round trip. Results align with
    /// `paths`; a file that fails to import yields `null` in its slot so one
    /// bad file cannot fail the whole batch.
    ImportPathAttachments {
        #[ts(type = "Array<string>")]
        paths: Vec<PathBuf>,
    },
    ReadBlob {
        reference: String,
    },
    ReadAttachment {
        reference: String,
        path: PathBuf,
    },
    SweepBlobs,
    /// Fork a persisted task through one completed provider turn.
    ///
    /// This is intentionally a daemon-owned operation: provider-native
    /// conversation state, Git checkpoint refs, and SQLite all live on the
    /// daemon host and must move together for remote clients.
    ForkSessionFromResponse {
        turn_count: usize,
    },
    /// Restore a task and its provider conversation to immediately before a
    /// prior user message. The client can then submit the edited replacement
    /// as an ordinary new turn.
    RewindSessionToMessage {
        turn_count: usize,
    },
    ForkProviderSession {
        request: ProviderSessionForkRequest,
    },
    Workspace {
        operation: WorkspaceOperation,
    },
    OpenTerminal {
        #[ts(type = "string")]
        cwd: PathBuf,
        cols: u16,
        rows: u16,
    },
    WriteTerminal {
        #[serde(with = "base64_bytes")]
        #[ts(type = "string")]
        data: Vec<u8>,
    },
    ResizeTerminal {
        cols: u16,
        rows: u16,
    },
    CloseTerminal,
    CloseSession,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct WireDriverStartOptions {
    pub provider: String,
    pub binary: PathBuf,
    pub cwd: PathBuf,
    pub mode: String,
    pub interaction_mode: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
    pub context_window: Option<String>,
    pub agent_preset: Option<String>,
    pub computer_use_enabled: bool,
    pub provider_cursor: Option<Value>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct WireSessionOptions {
    pub mode: String,
    pub interaction_mode: String,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub service_tier: Option<String>,
    pub context_window: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct WireComputerToolRequest {
    pub call_id: String,
    pub tool: String,
    pub arguments: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct WireDriverEvent {
    pub kind: String,
    #[serde(default)]
    pub payload: Value,
}

impl WireDriverEvent {
    pub fn new(kind: impl Into<String>, payload: Value) -> Self {
        Self {
            kind: kind.into(),
            payload,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub struct SequencedEvent {
    pub session_id: Uuid,
    pub runtime_id: Uuid,
    /// Changes whenever the daemon restarts, so a reused runtime id can begin
    /// again at sequence one without being mistaken for an old event.
    pub epoch: Uuid,
    pub sequence: u64,
    pub event: WireDriverEvent,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ServerMessage {
    Hello {
        protocol_version: u32,
        daemon_version: String,
    },
    Rejected {
        message: String,
    },
    Response {
        request_id: Uuid,
        outcome: ResponseOutcome,
    },
    Event(SequencedEvent),
    /// The client's replay cursor fell off the back of the daemon's in-memory
    /// journal: the events between it and `first_available` were evicted and
    /// are gone for good.
    ///
    /// Replay cannot make such a client whole — applying the surviving tail on
    /// top of its projection would leave a hole in the transcript rather than
    /// an obvious error. So the daemon says so instead of pretending, and the
    /// client refetches the session. A phone backgrounded through a long run
    /// is the ordinary way to get here, not the exotic one: the journal is a
    /// few thousand events deep and a streaming turn spends them in minutes.
    ReplayGap {
        session_id: Uuid,
        runtime_id: Uuid,
        epoch: Uuid,
        /// The oldest sequence the journal still holds. Everything the client
        /// had not already seen below this is unrecoverable.
        first_available: u64,
    },
    /// The daemon-owned project/task catalog changed through another client.
    /// Clients should invalidate their lightweight task-state snapshot; live
    /// runtime events continue through [`Self::Event`].
    TaskStateChanged {
        revision: u64,
    },
    ShuttingDown,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "status",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ResponseOutcome {
    Ok { payload: ResponsePayload },
    Error { error: RpcError },
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ResponsePayload {
    Ack,
    SessionRuntime {
        runtime_id: Option<Uuid>,
        supports_steer: bool,
    },
    Started {
        supports_steer: bool,
    },
    OptionsApplied {
        applied: bool,
    },
    Cursor {
        cursor: Option<Value>,
    },
    Settings {
        settings: DaemonSettings,
    },
    ProviderProbe {
        probe: ProviderProbe,
        version: Option<String>,
    },
    PlanUsage {
        usage: Option<PlanUsage>,
    },
    ComputerPermissions {
        permissions: ComputerPermissions,
    },
    UsageHistory {
        history: UsageHistory,
    },
    SkillsCatalog {
        catalog: SkillsCatalog,
    },
    TaskState {
        projects: Vec<Project>,
        sessions: Vec<AgentSession>,
        default_cwd: PathBuf,
        projectless_root: Option<PathBuf>,
    },
    ChildTaskCreated {
        session: AgentSession,
        start_options: WireDriverStartOptions,
    },
    TaskSummary {
        summary: TaskSummary,
    },
    TaskSummaries {
        summaries: Vec<TaskSummary>,
    },
    ProviderModels {
        provider: ProviderKind,
        models: Vec<crate::model::ProviderModel>,
    },
    TaskStateSaved {
        sessions: Vec<AgentSession>,
    },
    Session {
        session: Option<AgentSession>,
    },
    SessionMessageMatches {
        matches: Vec<SessionMessageMatch>,
    },
    ComposerDrafts {
        drafts: ComposerDrafts,
    },
    BlobStored {
        reference: String,
        path: PathBuf,
    },
    AttachmentStored {
        attachment: StoredAttachment,
    },
    AttachmentsStored {
        attachments: Vec<Option<StoredAttachment>>,
    },
    BlobData {
        #[serde(with = "base64_bytes")]
        #[ts(type = "string")]
        bytes: Vec<u8>,
    },
    ProviderSessionForked {
        result: ProviderSessionFork,
    },
    SessionForked {
        session: AgentSession,
        checkpoint_warning: Option<String>,
    },
    SessionRewound {
        session: AgentSession,
        cleanup_warning: Option<String>,
    },
    Workspace {
        result: WorkspaceResult,
    },
}

/// Why a command failed, when the reason is something a client must act on
/// differently from an ordinary failure.
///
/// Absent on a plain error. A transport drop, a timeout, and a daemon bug all
/// carry no kind, so a client can tell them apart from a deliberate refusal.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
pub enum RpcErrorKind {
    /// The daemon considered the command and declined it. The request was
    /// well-formed and arrived intact, so retrying it changes nothing until
    /// the state that provoked the refusal changes. Show it to the user.
    Refused,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct RpcError {
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<RpcErrorKind>,
}

impl RpcError {
    /// A refusal: the daemon understood the command and declined it.
    pub fn refused(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            kind: Some(RpcErrorKind::Refused),
        }
    }

    pub fn is_refusal(&self) -> bool {
        self.kind == Some(RpcErrorKind::Refused)
    }
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RpcError {}

impl From<anyhow::Error> for RpcError {
    fn from(error: anyhow::Error) -> Self {
        // A backend that returned a typed error keeps its kind; anything else
        // is an ordinary failure and reaches the client as bare text.
        match error.downcast::<RpcError>() {
            Ok(error) => error,
            Err(error) => Self {
                message: error.to_string(),
                kind: None,
            },
        }
    }
}

mod base64_bytes {
    use base64::Engine as _;
    use serde::{Deserialize as _, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&base64::engine::general_purpose::STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_payloads_use_base64_json_strings() {
        let payload = ResponsePayload::BlobData {
            bytes: vec![0, 1, 2, 255],
        };
        let json = serde_json::to_value(&payload).unwrap();

        assert_eq!(json["bytes"], "AAEC/w==");
        let ResponsePayload::BlobData { bytes } = serde_json::from_value(json).unwrap() else {
            panic!("unexpected payload variant");
        };
        assert_eq!(bytes, vec![0, 1, 2, 255]);

        let command = Command::WriteTerminal {
            data: vec![0, 1, 2, 255],
        };
        let json = serde_json::to_value(&command).unwrap();
        assert_eq!(json["type"], "writeTerminal");
        assert_eq!(json["data"], "AAEC/w==");
        let Command::WriteTerminal { data } = serde_json::from_value(json).unwrap() else {
            panic!("unexpected command variant");
        };
        assert_eq!(data, vec![0, 1, 2, 255]);
    }

    #[test]
    fn prompt_command_carries_the_submission_id() {
        let submission_id = Uuid::from_u128(13);
        let json = serde_json::to_value(Command::Prompt {
            prompt: "hello".into(),
            submission_id,
        })
        .unwrap();

        assert_eq!(json["type"], "prompt");
        assert_eq!(json["prompt"], "hello");
        assert_eq!(json["submissionId"], submission_id.to_string());
        assert_eq!(PROTOCOL_VERSION, 6);
    }

    #[test]
    fn response_fork_command_uses_stable_camel_case_fields() {
        let json =
            serde_json::to_value(Command::ForkSessionFromResponse { turn_count: 7 }).unwrap();

        assert_eq!(json["type"], "forkSessionFromResponse");
        assert_eq!(json["turnCount"], 7);
        assert_eq!(PROTOCOL_VERSION, 6);
    }

    #[test]
    fn message_rewind_command_uses_stable_camel_case_fields() {
        let json = serde_json::to_value(Command::RewindSessionToMessage { turn_count: 4 }).unwrap();

        assert_eq!(json["type"], "rewindSessionToMessage");
        assert_eq!(json["turnCount"], 4);
        assert_eq!(PROTOCOL_VERSION, 6);
    }

    #[test]
    fn handshake_and_replay_field_names_are_stable() {
        let session_id = Uuid::nil();
        let runtime_id = Uuid::from_u128(1);
        let message = ClientMessage::Hello {
            protocol_version: PROTOCOL_VERSION,
            token: "secret".into(),
            client_id: Uuid::from_u128(2),
            resume_from: vec![ReplayCursor {
                session_id,
                runtime_id,
                epoch: Uuid::from_u128(3),
                sequence: 9,
            }],
        };
        let json = serde_json::to_value(message).unwrap();

        assert_eq!(json["type"], "hello");
        assert_eq!(json["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(json["resumeFrom"][0]["sessionId"], session_id.to_string());
        assert_eq!(json["resumeFrom"][0]["runtimeId"], runtime_id.to_string());
        assert_eq!(
            json["resumeFrom"][0]["epoch"],
            Uuid::from_u128(3).to_string()
        );
        assert!(json.get("protocol_version").is_none());
    }

    #[test]
    fn composer_draft_changes_have_stable_wire_keys() {
        let project_id = Uuid::from_u128(7);
        let command = Command::ApplyComposerDraftChanges {
            changes: vec![ComposerDraftChange {
                target: crate::persistence::ComposerDraftTarget::NewSession { project_id },
                draft: Some(crate::persistence::ComposerDraft {
                    text: "unfinished".into(),
                    attachments: Vec::new(),
                }),
            }],
        };
        let json = serde_json::to_value(command).unwrap();

        assert_eq!(json["type"], "applyComposerDraftChanges");
        assert_eq!(json["changes"][0]["target"]["type"], "newSession");
        assert_eq!(
            json["changes"][0]["target"]["projectId"],
            project_id.to_string()
        );
        assert_eq!(json["changes"][0]["draft"]["text"], "unfinished");
    }
}

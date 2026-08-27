//! The projects and tasks the Demo Daemon serves.
//!
//! Identifiers are fixed constants rather than fresh v4 UUIDs, so a client
//! that reconnects — or a second client watching the same daemon — sees the
//! same catalog it saw before. Times are anchored to process start instead of
//! to a date in the fixture, so the list still reads as recent work months
//! after the demo host was provisioned.

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use shidou_protocol::model::{
    ActivityFileChange, ActivityFileChangeStatus, ActivityItem, ActivityKind, AgentSession,
    AgentTurn, Checkpoint, CheckpointFile, CheckpointStatus, ContextUsage, InteractionMode,
    Message, MessageRole, Project, ProjectWorkspaceDefault, ProviderKind, ProviderResumeCursor,
    ReportedCommand, RuntimeMode, SessionStatus, SessionWorkspace, TranscriptBlock, TurnStatus,
};
use shidou_protocol::persistence::SessionMessageMatch;
use uuid::Uuid;

use crate::tree;

/// Fixture identifiers are derived from their kind and position rather than
/// minted, so the catalog a client reconnects to is the one it left — and so a
/// demo id is recognizable on sight in a log line.
const fn fixture_id(kind: u16, index: u16) -> Uuid {
    Uuid::from_u128(
        0x5EED_0000_0000_0000_0000_0000_0000_0000 | ((kind as u128) << 16) | (index as u128),
    )
}

const PROJECT: u16 = 1;
const SESSION: u16 = 2;
const TURN: u16 = 3;
const MESSAGE: u16 = 4;
const ACTIVITY: u16 = 5;

pub const SHIDOU_PROJECT: Uuid = fixture_id(PROJECT, 1);
pub const NOTES_PROJECT: Uuid = fixture_id(PROJECT, 2);

/// The Demo Session: the one a client's scripted turn plays into.
pub const DEMO_SESSION: Uuid = fixture_id(SESSION, 1);
/// The Waiting Session: blocked on the user, so the list has something to mark.
pub const WAITING_SESSION: Uuid = fixture_id(SESSION, 2);
const AUDIT_SESSION: Uuid = fixture_id(SESSION, 3);
const NOTES_SESSION: Uuid = fixture_id(SESSION, 4);

const MINUTE: u64 = 60;
const HOUR: u64 = 60 * MINUTE;
const DAY: u64 = 24 * HOUR;

/// Unix seconds at process start. Every fixture time is an offset from this,
/// which keeps the catalog stable for the life of the daemon and recent for
/// the life of the host.
pub fn epoch() -> u64 {
    static EPOCH: OnceLock<u64> = OnceLock::new();
    *EPOCH.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_secs())
            .unwrap_or_default()
    })
}

fn ago(seconds: u64) -> u64 {
    epoch().saturating_sub(seconds)
}

pub fn projects() -> Vec<Project> {
    vec![
        Project {
            id: SHIDOU_PROJECT,
            name: "shidou".into(),
            path: tree::WORKSPACE_ROOT.into(),
            created_at: ago(30 * DAY),
            workspace_default: ProjectWorkspaceDefault::Local,
        },
        Project {
            id: NOTES_PROJECT,
            name: "notes".into(),
            path: tree::NOTES_ROOT.into(),
            created_at: ago(90 * DAY),
            workspace_default: ProjectWorkspaceDefault::Local,
        },
    ]
}

/// The catalog projection: titles, status and recency, with no transcripts.
pub fn catalog() -> Vec<AgentSession> {
    hydrated_sessions()
        .iter()
        .map(AgentSession::list_projection)
        .collect()
}

/// One task with its full transcript, as `HydrateSession` returns it.
pub fn hydrate(session_id: Uuid) -> Option<AgentSession> {
    hydrated_sessions()
        .into_iter()
        .find(|session| session.id == session_id)
}

pub fn exists(session_id: Uuid) -> bool {
    hydrated_sessions()
        .iter()
        .any(|session| session.id == session_id)
}

pub fn search(query: &str, limit: usize) -> Vec<SessionMessageMatch> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return Vec::new();
    }
    hydrated_sessions()
        .iter()
        .flat_map(|session| session.messages.iter().map(|message| (session.id, message)))
        .filter(|(_, message)| message.content.to_lowercase().contains(&needle))
        .take(limit)
        .map(|(session_id, message)| SessionMessageMatch {
            session_id,
            source: message.role,
            snippet: snippet(&message.content, &needle),
        })
        .collect()
}

/// A window of the message around the first match, so the result list shows
/// the hit rather than the message's opening words.
fn snippet(content: &str, needle: &str) -> String {
    const CONTEXT: usize = 48;
    let Some(hit) = content.to_lowercase().find(needle) else {
        return content.chars().take(CONTEXT * 2).collect();
    };
    let start = content[..hit]
        .char_indices()
        .rev()
        .take(CONTEXT)
        .last()
        .map(|(index, _)| index)
        .unwrap_or(hit);
    let end = content[hit..]
        .char_indices()
        .take(needle.len() + CONTEXT)
        .last()
        .map(|(index, character)| hit + index + character.len_utf8())
        .unwrap_or(content.len());
    let mut snippet = String::new();
    if start > 0 {
        snippet.push('…');
    }
    snippet.push_str(content[start..end].trim());
    if end < content.len() {
        snippet.push('…');
    }
    snippet
}

fn hydrated_sessions() -> Vec<AgentSession> {
    vec![
        demo_session(),
        waiting_session(),
        audit_session(),
        notes_session(),
    ]
}

/// The fields every fixture task shares, with `AgentSession::new`'s minted id
/// replaced by a fixed one.
fn base(id: Uuid, project_id: Uuid, provider: ProviderKind, auto_title: &str) -> AgentSession {
    AgentSession {
        id,
        auto_title: Some(auto_title.to_owned()),
        project_id,
        provider,
        interaction_mode: InteractionMode::Build,
        runtime_mode: RuntimeMode::FullAccess,
        workspace: SessionWorkspace::Local,
        available_commands: ["compact", "review", "changelog"]
            .into_iter()
            .map(|name| ReportedCommand {
                name: name.to_owned(),
                description: String::new(),
            })
            .collect(),
        ..AgentSession::new(project_id, provider)
    }
}

fn demo_session() -> AgentSession {
    let turn_id = fixture_id(TURN, 1);
    let started = ago(6 * MINUTE);
    let completed = ago(5 * MINUTE);
    AgentSession {
        model: Some("claude-opus-5".into()),
        status: SessionStatus::Idle,
        created_at: started,
        updated_at: completed,
        last_reply_at: Some(completed),
        provider_cursor: Some(ProviderResumeCursor::Claude {
            session_id: "demo-session".into(),
            resume_at: None,
        }),
        context_usage: Some(ContextUsage {
            tokens: 18_420,
            window: Some(200_000),
        }),
        messages: vec![
            message(
                1,
                turn_id,
                MessageRole::User,
                "Where does this service do rate limiting?",
                started,
            ),
            message(
                2,
                turn_id,
                MessageRole::Assistant,
                RATE_LIMIT_ANSWER,
                completed,
            ),
        ],
        transcript_blocks: vec![TranscriptBlock {
            after_message: 1,
            turn_id: Some(turn_id),
            activities: vec![
                ActivityItem {
                    id: fixture_id(ACTIVITY, 1),
                    display_target: Some(tree::EDITED_FILE.into()),
                    output: Some("48 lines · token bucket keyed by API token".into()),
                    ..ActivityItem::new(
                        Some("demo-read-limiter".into()),
                        ActivityKind::FileRead,
                        "Read",
                        Some(tree::EDITED_FILE.into()),
                        true,
                    )
                },
                ActivityItem {
                    id: fixture_id(ACTIVITY, 2),
                    display_target: Some("src".into()),
                    output: Some("limiter.rs\nmain.rs\nroutes.rs".into()),
                    ..ActivityItem::new(
                        Some("demo-list-src".into()),
                        ActivityKind::FileList,
                        "List",
                        Some("src".into()),
                        true,
                    )
                },
            ],
        }],
        turns: vec![AgentTurn {
            id: turn_id,
            turn_count: 1,
            status: TurnStatus::Completed,
            provider_turn_started: true,
            provider_resume_at: None,
            started_at: started,
            completed_at: Some(completed),
            checkpoint: None,
        }],
        ..base(
            DEMO_SESSION,
            SHIDOU_PROJECT,
            ProviderKind::Claude,
            "Rate limiting in the public API",
        )
    }
}

fn waiting_session() -> AgentSession {
    let turn_id = fixture_id(TURN, 2);
    let started = ago(2 * MINUTE);
    AgentSession {
        model: Some("gpt-5.6-sol".into()),
        status: SessionStatus::Waiting,
        created_at: ago(20 * MINUTE),
        updated_at: started,
        last_reply_at: Some(started),
        messages: vec![message(
            3,
            turn_id,
            MessageRole::User,
            "Wire the pairing QR into the settings pane.",
            started,
        )],
        transcript_blocks: Vec::new(),
        turns: vec![AgentTurn {
            id: turn_id,
            turn_count: 1,
            status: TurnStatus::Running,
            provider_turn_started: true,
            provider_resume_at: None,
            started_at: started,
            completed_at: None,
            checkpoint: None,
        }],
        ..base(
            WAITING_SESSION,
            SHIDOU_PROJECT,
            ProviderKind::Codex,
            "Pairing QR in settings",
        )
    }
}

fn audit_session() -> AgentSession {
    let turn_id = fixture_id(TURN, 3);
    let started = ago(3 * HOUR);
    let completed = ago(3 * HOUR - 4 * MINUTE);
    AgentSession {
        model: Some("claude-opus-5".into()),
        status: SessionStatus::Idle,
        created_at: started,
        updated_at: completed,
        last_reply_at: Some(completed),
        messages: vec![
            message(
                4,
                turn_id,
                MessageRole::User,
                "Audit the daemon's replay journal for unbounded growth.",
                started,
            ),
            message(
                5,
                turn_id,
                MessageRole::Assistant,
                REPLAY_AUDIT_ANSWER,
                completed,
            ),
        ],
        transcript_blocks: Vec::new(),
        turns: vec![AgentTurn {
            id: turn_id,
            turn_count: 1,
            status: TurnStatus::Completed,
            provider_turn_started: true,
            provider_resume_at: None,
            started_at: started,
            completed_at: Some(completed),
            checkpoint: Some(Checkpoint {
                turn_count: 1,
                git_ref: "refs/shidou/demo/audit/1".into(),
                status: CheckpointStatus::Ready,
                files: vec![CheckpointFile {
                    path: "crates/shidou-core/src/server.rs".into(),
                    additions: 6,
                    deletions: 1,
                }],
                additions: 6,
                deletions: 1,
                created_at: completed,
            }),
        }],
        ..base(
            AUDIT_SESSION,
            SHIDOU_PROJECT,
            ProviderKind::Claude,
            "Replay journal audit",
        )
    }
}

fn notes_session() -> AgentSession {
    let turn_id = fixture_id(TURN, 4);
    let started = ago(2 * DAY);
    let completed = ago(2 * DAY - 3 * MINUTE);
    AgentSession {
        title: "Release notes for 0.4.1".into(),
        model: Some("gpt-5.6-sol".into()),
        status: SessionStatus::Idle,
        created_at: started,
        updated_at: completed,
        last_reply_at: Some(completed),
        messages: vec![
            message(
                6,
                turn_id,
                MessageRole::User,
                "Draft release notes for 0.4.1 from this week's commits.",
                started,
            ),
            message(
                7,
                turn_id,
                MessageRole::Assistant,
                RELEASE_NOTES_ANSWER,
                completed,
            ),
        ],
        transcript_blocks: Vec::new(),
        turns: vec![AgentTurn {
            id: turn_id,
            turn_count: 1,
            status: TurnStatus::Completed,
            provider_turn_started: true,
            provider_resume_at: None,
            started_at: started,
            completed_at: Some(completed),
            checkpoint: None,
        }],
        ..base(
            NOTES_SESSION,
            NOTES_PROJECT,
            ProviderKind::Codex,
            "Release notes for 0.4.1",
        )
    }
}

fn message(
    index: u16,
    turn_id: Uuid,
    role: MessageRole,
    content: &str,
    created_at: u64,
) -> Message {
    Message {
        id: fixture_id(MESSAGE, index),
        turn_id: Some(turn_id),
        created_at,
        ..Message::new(role, content)
    }
}

/// The file change the scripted turn produces, reused by the transcript row
/// so the transcript and the changes surface describe the same edit.
pub fn limiter_file_change() -> ActivityFileChange {
    ActivityFileChange {
        path: tree::EDITED_FILE.to_owned(),
        additions: Some(tree::ADDITIONS),
        deletions: Some(tree::DELETIONS),
        status: Some(ActivityFileChangeStatus::Modified),
        diff: Some(tree::LIMITER_PATCH.to_owned()),
    }
}

const RATE_LIMIT_ANSWER: &str = "\
Rate limiting lives in `src/limiter.rs`. Every handler in `src/routes.rs` runs \
behind `Limiter::admit`, which is keyed by the caller's API token.

Each client gets a token bucket holding up to `BURST` tokens. `admit` spends \
one token per request and refuses the request when the bucket is empty.";

const REPLAY_AUDIT_ANSWER: &str = "\
The journal is bounded. `Hub::emit` pushes into a per-runtime `VecDeque` and \
pops the front past `MAX_REPLAY_EVENTS_PER_SESSION`, and `begin_runtime` drops \
every entry for a session when its runtime is replaced.

The one unbounded path was terminal output, which is why it goes through \
`send_ephemeral` and is never journaled at all.";

const RELEASE_NOTES_ANSWER: &str = "\
## 0.4.1

- Pair with a Mac daemon by scanning its QR, and fail over between the \
addresses it advertises.
- Show the remaining context window in the composer.
- Keep pairing off the main thread, so a slow candidate address no longer \
trips the watchdog.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_catalog_carries_more_than_one_session_and_one_of_them_is_waiting() {
        let catalog = catalog();

        assert!(catalog.len() > 1);
        assert_eq!(
            catalog
                .iter()
                .filter(|session| session.status == SessionStatus::Waiting)
                .count(),
            1
        );
        assert!(
            catalog
                .iter()
                .any(|session| session.project_id == NOTES_PROJECT)
        );
    }

    #[test]
    fn catalog_rows_are_skeletons_and_hydration_carries_the_transcript() {
        let listed = catalog()
            .into_iter()
            .find(|session| session.id == DEMO_SESSION)
            .unwrap();

        assert!(listed.messages.is_empty());
        assert!(!listed.detail_loaded);
        let hydrated = hydrate(DEMO_SESSION).unwrap();
        assert!(hydrated.detail_loaded);
        assert_eq!(hydrated.messages.len(), 2);
        assert_eq!(hydrated.transcript_blocks[0].activities.len(), 2);
    }

    #[test]
    fn every_session_identifier_is_stable_across_calls() {
        let first = catalog();
        let second = catalog();

        assert_eq!(
            first.iter().map(|session| session.id).collect::<Vec<_>>(),
            second.iter().map(|session| session.id).collect::<Vec<_>>()
        );
        assert_eq!(
            hydrate(DEMO_SESSION).unwrap().messages[0].id,
            hydrate(DEMO_SESSION).unwrap().messages[0].id
        );
    }

    #[test]
    fn the_list_sorts_by_recency_with_the_demo_session_newest() {
        let mut catalog = catalog();
        catalog.sort_by_key(|session| std::cmp::Reverse(session.last_reply_at));

        assert_eq!(catalog[0].id, WAITING_SESSION);
        assert_eq!(catalog[1].id, DEMO_SESSION);
    }

    #[test]
    fn search_finds_the_hit_and_windows_the_snippet_around_it() {
        let matches = search("token bucket", 10);

        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].session_id, DEMO_SESSION);
        assert!(matches[0].snippet.contains("token bucket"));
        assert!(search("", 10).is_empty());
        assert!(search("nothing here matches", 10).is_empty());
    }

    #[test]
    fn the_transcript_file_change_carries_the_same_diff_as_the_review_surface() {
        let change = limiter_file_change();

        assert_eq!(change.additions, Some(tree::ADDITIONS));
        assert_eq!(change.diff.as_deref(), Some(tree::LIMITER_PATCH));
    }
}

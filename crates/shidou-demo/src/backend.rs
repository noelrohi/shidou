//! The [`Backend`] the Demo Daemon serves.
//!
//! Every command is answered from the fixture modules in this crate. Nothing
//! here spawns a process, opens a file, reaches the network, or spends
//! provider credit — which is what makes it safe to publish this daemon's
//! token inside the app.
//!
//! Commands that would mutate the host are refused with a message that says
//! why, rather than quietly pretending to succeed. A reviewer who taps Commit
//! should learn that the demo is read-only, not watch a button do nothing.

use std::collections::HashMap;

use anyhow::{Context as _, anyhow, bail};
use parking_lot::Mutex;
use shidou_core::{Backend, Command, EventSink, Request, ResponsePayload};
use shidou_protocol::model::{
    BackgroundWorkEvent, BackgroundWorkItem, BackgroundWorkKey, BackgroundWorkStatus, Checkpoint,
    CheckpointStatus, DriverEvent, ProviderKind,
};
use shidou_protocol::persistence::ComposerDrafts;
use shidou_protocol::workspace::{WorkspaceOperation, WorkspaceResult};
use uuid::Uuid;

use crate::blobs::Blobs;
use crate::log::{self, Record};
use crate::script::{self, Controls, emit};
use crate::{catalog, sessions, tree};

#[derive(Default)]
pub struct DemoBackend {
    blobs: Blobs,
    runtimes: Mutex<HashMap<Uuid, Runtime>>,
}

struct Runtime {
    id: Uuid,
    controls: Controls,
    /// Prompts this runtime has taken. The first one plays the showcase.
    prompts: usize,
}

impl DemoBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// The controls for the runtime a request names, or an error naming the
    /// mismatch — the same check the real daemon makes before touching a
    /// provider process.
    fn controls(&self, session_id: Uuid, runtime_id: Uuid) -> anyhow::Result<Controls> {
        let runtimes = self.runtimes.lock();
        let runtime = runtimes
            .get(&session_id)
            .ok_or_else(|| anyhow!("demo session {session_id} is not running"))?;
        if runtime.id != runtime_id {
            bail!(
                "demo session {session_id} belongs to runtime {}",
                runtime.id
            );
        }
        Ok(runtime.controls.clone())
    }

    /// Claims a session's runtime for one turn and picks the script it plays.
    ///
    /// The showcase belongs to the Demo Session and to any task the client
    /// just created — the two ways someone arrives here with nothing to read
    /// yet. Everything after that gets the canned reply, so a composer that
    /// keeps working never repeats the whole demo.
    fn begin_turn(
        &self,
        session_id: Uuid,
        runtime_id: Uuid,
        prompt: &str,
    ) -> anyhow::Result<(script::Turn, Vec<script::Beat>)> {
        let mut runtimes = self.runtimes.lock();
        let runtime = runtimes
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("demo session {session_id} is not running"))?;
        if runtime.id != runtime_id {
            bail!(
                "demo session {session_id} belongs to runtime {}",
                runtime.id
            );
        }
        let turn = runtime
            .controls
            .begin_turn()
            .ok_or_else(|| anyhow!("the demo is still answering the previous message"))?;
        runtime.prompts += 1;
        let showcase = runtime.prompts == 1
            && (session_id == sessions::DEMO_SESSION || !sessions::exists(session_id));
        Ok((
            turn,
            if showcase {
                script::showcase()
            } else {
                script::canned_reply(prompt)
            },
        ))
    }

    /// Runs `work` on its own thread so the session's request mailbox stays
    /// free to cancel or answer the turn while it plays.
    fn spawn(&self, label: &str, work: impl FnOnce() + Send + 'static) {
        if let Err(error) = std::thread::Builder::new()
            .name(format!("shidou-demo-{label}"))
            .spawn(work)
        {
            eprintln!("could not start the demo's {label} thread: {error}");
        }
    }
}

impl Backend for DemoBackend {
    fn handle(&self, request: Request, events: EventSink) -> anyhow::Result<ResponsePayload> {
        let session_id = request.session_id;
        let runtime_id = request.runtime_id;
        match request.command {
            // ---- Session runtime -------------------------------------------------
            Command::Start { .. } => {
                let controls = Controls::default();
                let previous = self.runtimes.lock().insert(
                    session_id,
                    Runtime {
                        id: runtime_id,
                        controls,
                        prompts: 0,
                    },
                );
                if let Some(previous) = previous {
                    previous.controls.cancel();
                }
                log::record(Record::RuntimeStarted {
                    session: &session_id.to_string(),
                });
                self.spawn("handshake", move || {
                    script::announce(script::handshake(), &events)
                });
                Ok(ResponsePayload::Started {
                    supports_steer: true,
                })
            }
            Command::AttachSession => Ok(ResponsePayload::SessionRuntime {
                runtime_id: self
                    .runtimes
                    .lock()
                    .get(&session_id)
                    .map(|runtime| runtime.id),
                supports_steer: true,
            }),
            Command::CloseSession => {
                let mut runtimes = self.runtimes.lock();
                if runtimes
                    .get(&session_id)
                    .is_some_and(|runtime| runtime.id == runtime_id)
                    && let Some(runtime) = runtimes.remove(&session_id)
                {
                    runtime.controls.cancel();
                }
                Ok(ResponsePayload::Ack)
            }
            Command::Prompt { prompt, .. } => {
                let (turn, beats) = self.begin_turn(session_id, runtime_id, &prompt)?;
                log::record(Record::Prompt {
                    session: &session_id.to_string(),
                    text: &prompt,
                });
                self.spawn("turn", move || script::play(beats, &events, turn));
                Ok(ResponsePayload::Ack)
            }
            Command::Steer { prompt } => {
                self.controls(session_id, runtime_id)?;
                log::record(Record::Prompt {
                    session: &session_id.to_string(),
                    text: &prompt,
                });
                emit(&events, DriverEvent::SteerAccepted { message: prompt })?;
                Ok(ResponsePayload::Ack)
            }
            Command::Cancel => {
                self.controls(session_id, runtime_id)?.cancel();
                Ok(ResponsePayload::Ack)
            }
            Command::Respond { request_id, .. } | Command::RespondUserInput { request_id, .. } => {
                self.controls(session_id, runtime_id)?.resolve(&request_id);
                Ok(ResponsePayload::Ack)
            }
            Command::ApplyOptions { .. } => Ok(ResponsePayload::OptionsApplied { applied: true }),

            // ---- Background work -------------------------------------------------
            Command::RefreshBackgroundWork => {
                self.controls(session_id, runtime_id)?;
                emit(
                    &events,
                    DriverEvent::BackgroundWork(BackgroundWorkEvent::ReconcileLive {
                        items: Vec::new(),
                    }),
                )?;
                Ok(ResponsePayload::Ack)
            }
            Command::StopBackgroundWork { key, .. } => {
                self.controls(session_id, runtime_id)?;
                let key: BackgroundWorkKey =
                    serde_json::from_value(key).context("invalid background-work key")?;
                emit(
                    &events,
                    DriverEvent::BackgroundWork(BackgroundWorkEvent::StopRequested(key.clone())),
                )?;
                emit(
                    &events,
                    DriverEvent::BackgroundWork(BackgroundWorkEvent::Upsert(BackgroundWorkItem {
                        can_stop: false,
                        ..BackgroundWorkItem::new(
                            key.kind,
                            key.provider_id,
                            "cargo watch",
                            BackgroundWorkStatus::Stopped,
                        )
                    })),
                )?;
                Ok(ResponsePayload::Ack)
            }

            // ---- Catalog and settings --------------------------------------------
            Command::GetSettings => Ok(ResponsePayload::Settings {
                settings: catalog::settings(),
            }),
            // Accepted so the settings pane behaves, and dropped: the fixture
            // is the same for every client and outlives none of them.
            Command::UpdateSettings { .. } => Ok(ResponsePayload::Ack),
            Command::ProbeProvider { provider, .. } => Ok(ResponsePayload::ProviderProbe {
                probe: catalog::provider_probe(provider),
                version: demo_cli_version(provider),
            }),
            Command::FetchPlanUsage { provider, .. } => Ok(ResponsePayload::PlanUsage {
                usage: catalog::plan_usage(provider),
            }),
            Command::ProbeComputerPermissions { .. } => Ok(ResponsePayload::ComputerPermissions {
                permissions: catalog::computer_permissions(),
            }),
            Command::LoadUsageHistory {
                window,
                project_roots,
            } => Ok(ResponsePayload::UsageHistory {
                history: catalog::usage_history(window, &project_roots),
            }),
            Command::LoadSkills { .. } => Ok(ResponsePayload::SkillsCatalog {
                catalog: catalog::skills(),
            }),
            Command::SetSkillsEnabled { .. } => Ok(ResponsePayload::Ack),
            Command::TrashSkills { .. } => refuse("trashSkills", "the demo cannot delete skills"),

            // ---- Tasks -----------------------------------------------------------
            Command::LoadTaskState => Ok(ResponsePayload::TaskState {
                projects: sessions::projects(),
                sessions: sessions::catalog(),
                default_cwd: tree::WORKSPACE_ROOT.into(),
                projectless_root: None,
            }),
            // Echoed back, never stored. The demo keeps no database, so a task
            // a client creates lives in that client and disappears with it.
            Command::SaveTaskState { sessions, .. } => Ok(ResponsePayload::TaskStateSaved {
                sessions: sessions
                    .iter()
                    .map(|session| session.list_projection())
                    .collect(),
            }),
            Command::RemoveSession | Command::RemoveProject { .. } => Ok(ResponsePayload::Ack),
            Command::HydrateSession { session_id } => Ok(ResponsePayload::Session {
                session: sessions::hydrate(session_id),
            }),
            Command::SearchSessionMessages { query, limit } => {
                Ok(ResponsePayload::SessionMessageMatches {
                    matches: sessions::search(&query, limit),
                })
            }
            Command::LoadComposerDrafts => Ok(ResponsePayload::ComposerDrafts {
                drafts: ComposerDrafts::default(),
            }),
            Command::SaveComposerDrafts { .. } | Command::ApplyComposerDraftChanges { .. } => {
                Ok(ResponsePayload::Ack)
            }

            // ---- Binary payloads -------------------------------------------------
            Command::StoreBlob { mime_type, bytes } => {
                let (reference, path) = self.blobs.store(&mime_type, bytes)?;
                Ok(ResponsePayload::BlobStored { reference, path })
            }
            Command::ImportPathAttachment { path } => Ok(ResponsePayload::AttachmentStored {
                attachment: self.blobs.attachment(&path).ok_or_else(|| {
                    anyhow!(
                        "{} is not part of the Shidou demo workspace",
                        path.display()
                    )
                })?,
            }),
            Command::ImportPathAttachments { paths } => Ok(ResponsePayload::AttachmentsStored {
                attachments: paths
                    .iter()
                    .map(|path| self.blobs.attachment(path))
                    .collect(),
            }),
            Command::ImportAttachment { .. } => {
                refuse("importAttachment", "the demo cannot store uploaded files")
            }
            Command::ReadBlob { reference } | Command::ReadAttachment { reference, .. } => {
                Ok(ResponsePayload::BlobData {
                    bytes: self
                        .blobs
                        .read(&reference)
                        .ok_or_else(|| anyhow!("unknown demo reference {reference}"))?,
                })
            }
            Command::SweepBlobs => Ok(ResponsePayload::Ack),

            // ---- Workspace -------------------------------------------------------
            Command::Workspace { operation } => Ok(ResponsePayload::Workspace {
                result: workspace(operation)?,
            }),

            // ---- Everything the fixture has no side effects for -------------------
            Command::Rollback { .. } | Command::Fork { .. } => {
                Ok(ResponsePayload::Cursor { cursor: None })
            }
            Command::ForkSessionFromResponse { .. }
            | Command::RewindSessionToMessage { .. }
            | Command::ForkProviderSession { .. } => {
                refuse("fork", "the demo session cannot be forked or rewound")
            }
            Command::RunComputerTool { .. }
            | Command::RejectComputerTool { .. }
            | Command::CancelComputerUse => {
                refuse("computerUse", "the demo has no computer to drive")
            }
            Command::OpenTerminal { .. }
            | Command::WriteTerminal { .. }
            | Command::ResizeTerminal { .. }
            | Command::CloseTerminal => refuse("terminal", "the demo runs no shell"),
        }
    }

    fn shutdown(&self) {
        log::record(Record::Stopping);
        for (_, runtime) in self.runtimes.lock().drain() {
            runtime.controls.cancel();
        }
    }
}

fn workspace(operation: WorkspaceOperation) -> anyhow::Result<WorkspaceResult> {
    Ok(match operation {
        WorkspaceOperation::ListTree {
            root,
            expanded_paths,
        } => WorkspaceResult::WorkingTree {
            entries: tree::list_tree(&root, &expanded_paths)?,
        },
        WorkspaceOperation::BrowseDirectory { path } => {
            let directory = tree::browse(path.as_deref())?;
            WorkspaceResult::Directory {
                path: directory.path,
                parent: directory.parent,
                home: tree::HOME.into(),
                filesystem_root: "/".into(),
                entries: directory.entries,
            }
        }
        WorkspaceOperation::ReadTextFile {
            root,
            relative_path,
        } => WorkspaceResult::TextFile {
            content: tree::read_text_file(&root, &relative_path)?,
        },
        WorkspaceOperation::ListProjectFiles { root, cap } => WorkspaceResult::ProjectFiles {
            entries: tree::list_project_files(&root, cap)?,
        },
        WorkspaceOperation::DiscoverSlashCommands { .. } => WorkspaceResult::SlashCommands {
            commands: tree::slash_commands(),
        },
        WorkspaceOperation::InspectBranches { cwd } => WorkspaceResult::Branches {
            snapshot: Some(tree::branch_snapshot(&cwd)?),
        },
        WorkspaceOperation::InspectCommit { cwd } => WorkspaceResult::CommitSnapshot {
            snapshot: tree::commit_snapshot(&cwd)?,
        },
        WorkspaceOperation::CollectReviewDiff { cwd, source } => WorkspaceResult::ReviewDiff {
            data: tree::review_diff(&cwd, source)?,
        },
        WorkspaceOperation::GenerateCommitMessage { .. } => WorkspaceResult::CommitMessage {
            message: COMMIT_MESSAGE.to_owned(),
        },
        WorkspaceOperation::CaptureTurnStart { turn_count, .. }
        | WorkspaceOperation::CaptureTurn { turn_count, .. } => WorkspaceResult::Checkpoint {
            checkpoint: no_checkpoint(turn_count),
        },
        WorkspaceOperation::CaptureRef { .. } => WorkspaceResult::Checkpoint {
            checkpoint: no_checkpoint(0),
        },
        WorkspaceOperation::HasRef { .. } => WorkspaceResult::Bool { value: false },
        WorkspaceOperation::SessionTurnRefs { .. } => WorkspaceResult::TurnRefs {
            turn_counts: Vec::new(),
        },
        // Deleting a ref that was never captured is already what the caller
        // wanted, so these succeed rather than raising an error a client would
        // have to special-case.
        WorkspaceOperation::DeleteRef { .. }
        | WorkspaceOperation::DeleteTurnRefsAfter { .. }
        | WorkspaceOperation::DeleteSessionRefs { .. }
        | WorkspaceOperation::CopySessionRefs { .. }
        | WorkspaceOperation::MigrateProjectlessWorkspace { .. } => WorkspaceResult::Ack,

        WorkspaceOperation::WriteTextFile { .. } => {
            return refuse("writeTextFile", "the demo workspace is read-only");
        }
        WorkspaceOperation::Commit { .. } => {
            return refuse("commit", "the demo has no repository to commit to");
        }
        WorkspaceOperation::Push { .. } => {
            return refuse("push", "the demo has nowhere to push");
        }
        WorkspaceOperation::CheckoutBranch { .. } => {
            return refuse("checkoutBranch", "the demo cannot change branches");
        }
        WorkspaceOperation::CreateWorktree { .. } => {
            return refuse("createWorktree", "the demo cannot create worktrees");
        }
        WorkspaceOperation::RestoreRef { .. } => {
            return refuse("restoreRef", "the demo has no checkpoints to restore");
        }
        WorkspaceOperation::CreateProjectlessWorkspace { .. } => {
            return refuse(
                "createProjectlessWorkspace",
                "the demo cannot create a workspace on disk",
            );
        }
    })
}

/// The demo has no Git repository, so it has no checkpoints. `Unavailable` is
/// a state the app already handles: rollback is offered only where a
/// checkpoint is `Ready`.
fn no_checkpoint(turn_count: usize) -> Checkpoint {
    Checkpoint {
        turn_count,
        git_ref: String::new(),
        status: CheckpointStatus::Unavailable,
        files: Vec::new(),
        additions: 0,
        deletions: 0,
        created_at: sessions::epoch(),
    }
}

/// The demo reports plausible CLI versions for the providers it claims are
/// installed, so the settings pane renders a version row rather than a gap.
fn demo_cli_version(provider: ProviderKind) -> Option<String> {
    match provider {
        ProviderKind::Claude => Some("2.4.1".into()),
        ProviderKind::Codex => Some("0.58.0".into()),
        _ => None,
    }
}

/// Refuses a command that would have a side effect, recording what was asked
/// for and what the client was told.
fn refuse<T>(command: &str, reason: &str) -> anyhow::Result<T> {
    log::record(Record::Refused { command, reason });
    bail!("{reason}")
}

const COMMIT_MESSAGE: &str = "\
fix(limiter): refill token buckets continuously

Whole-second refill handed every client a full burst once a second, so the
sustained rate was the burst size rather than REFILL_PER_SECOND. Add tokens
proportional to elapsed time and clamp at the burst.

Also drop buckets nothing has touched recently, so the map stops growing with
every distinct caller.";

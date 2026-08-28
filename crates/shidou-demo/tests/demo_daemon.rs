//! End-to-end tests over the real wire.
//!
//! These drive a live `shidou_core::serve` with `DemoBackend` behind it,
//! through the same `DaemonClient` the desktop and iOS apps use. That is the
//! point of the crate — the app slices are built against this daemon over the
//! protocol rather than against in-memory fakes — so the tests that matter are
//! the ones that go through the socket.

use std::net::TcpListener;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use shidou_client::DaemonClient;
use shidou_demo::{DemoBackend, script, sessions, tree};
use shidou_protocol::model::{DriverEvent, UserInputAnswer};
use shidou_protocol::workspace::{ReviewDiffSource, WorkspaceOperation, WorkspaceResult};
use shidou_protocol::{Command, ReplayCursor, ResponsePayload, SequencedEvent};
use uuid::Uuid;

const TOKEN: &str = "demo-test-token";
/// Generous: the showcase streams several paragraphs at 120 tokens a second.
const TURN_DEADLINE: Duration = Duration::from_secs(60);

struct Daemon {
    address: String,
    shutdown: Arc<AtomicBool>,
    server: Option<std::thread::JoinHandle<()>>,
}

impl Daemon {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let shutdown = Arc::new(AtomicBool::new(false));
        let server_shutdown = shutdown.clone();
        let server = std::thread::spawn(move || {
            shidou_core::serve(
                listener,
                TOKEN.to_owned(),
                Arc::new(DemoBackend::new()),
                server_shutdown,
                shidou_core::ServerOptions::default(),
            )
            .unwrap();
        });
        Self {
            address,
            shutdown,
            server: Some(server),
        }
    }

    fn connect(&self) -> DaemonClient {
        DaemonClient::connect(&self.address, TOKEN.to_owned()).unwrap()
    }

    fn reconnect(&self, resume_from: Vec<ReplayCursor>) -> DaemonClient {
        DaemonClient::connect_with_resume(&self.address, TOKEN.to_owned(), resume_from).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.shutdown
            .store(true, std::sync::atomic::Ordering::Release);
        let _ = self.server.take().unwrap().join();
    }
}

/// Starts a runtime for `session_id` and returns its runtime id.
fn start(client: &DaemonClient, session_id: Uuid) -> Uuid {
    let runtime_id = Uuid::new_v4();
    let started = client
        .request(
            session_id,
            runtime_id,
            Command::Start {
                options: start_options(),
            },
        )
        .unwrap();
    assert!(matches!(started, ResponsePayload::Started { .. }));
    runtime_id
}

fn start_options() -> shidou_protocol::WireDriverStartOptions {
    shidou_protocol::WireDriverStartOptions {
        provider: "claude".into(),
        binary: "/opt/homebrew/bin/claude".into(),
        cwd: tree::WORKSPACE_ROOT.into(),
        mode: "fullAccess".into(),
        interaction_mode: "build".into(),
        model: Some("claude-opus-5".into()),
        reasoning_effort: None,
        service_tier: None,
        context_window: None,
        agent_preset: None,
        computer_use_enabled: false,
        provider_cursor: None,
    }
}

/// Reads events until `stop` accepts one, answering blocking prompts along the
/// way. Returns every event read, including the one that stopped it.
fn drain(
    client: &DaemonClient,
    events: &crossbeam_channel::Receiver<SequencedEvent>,
    session_id: Uuid,
    runtime_id: Uuid,
    stop: impl Fn(&DriverEvent) -> bool,
) -> Vec<SequencedEvent> {
    let deadline = Instant::now() + TURN_DEADLINE;
    let mut collected = Vec::new();
    while Instant::now() < deadline {
        let Ok(sequenced) = events.recv_timeout(deadline - Instant::now()) else {
            break;
        };
        let event = shidou_protocol::event_from_wire(sequenced.event.clone()).unwrap();
        collected.push(sequenced);
        match &event {
            DriverEvent::Permission {
                request_id,
                options,
                ..
            } => {
                client
                    .request(
                        session_id,
                        runtime_id,
                        Command::Respond {
                            request_id: request_id.clone(),
                            option_id: options[0].id.clone(),
                        },
                    )
                    .unwrap();
            }
            DriverEvent::UserInputRequested {
                request_id,
                questions,
            } => {
                client
                    .request(
                        session_id,
                        runtime_id,
                        Command::RespondUserInput {
                            request_id: request_id.clone(),
                            answers: questions
                                .iter()
                                .map(|question| UserInputAnswer {
                                    question_id: question.id.clone(),
                                    answers: vec![question.options[0].label.clone()],
                                })
                                .collect(),
                        },
                    )
                    .unwrap();
            }
            _ => {}
        }
        if stop(&event) {
            return collected;
        }
    }
    panic!("the demo never reached the event the test was waiting for");
}

fn kinds(events: &[SequencedEvent]) -> Vec<&str> {
    events
        .iter()
        .map(|event| event.event.kind.as_str())
        .collect()
}

fn text(events: &[SequencedEvent]) -> String {
    events
        .iter()
        .filter(|event| event.event.kind == "textDelta")
        .filter_map(|event| event.event.payload.as_str())
        .collect()
}

#[test]
fn the_catalog_lists_more_than_one_session_and_marks_the_waiting_one() {
    let daemon = Daemon::start();
    let client = daemon.connect();

    let ResponsePayload::TaskState {
        projects,
        sessions: listed,
        default_cwd,
        ..
    } = client
        .request(Uuid::nil(), Uuid::nil(), Command::LoadTaskState)
        .unwrap()
    else {
        panic!("the demo answered a task-state load with something else");
    };

    assert_eq!(projects.len(), 2);
    assert!(listed.len() > 1);
    assert!(
        listed
            .iter()
            .any(|session| session.id == sessions::WAITING_SESSION
                && session.status == shidou_protocol::model::SessionStatus::Waiting)
    );
    assert_eq!(default_cwd, std::path::Path::new(tree::WORKSPACE_ROOT));
    assert!(
        !default_cwd.exists(),
        "the demo workspace must not resolve against the host filesystem"
    );
}

#[test]
fn the_demo_session_hydrates_with_a_transcript_and_is_searchable() {
    let daemon = Daemon::start();
    let client = daemon.connect();

    let ResponsePayload::Session { session } = client
        .request(
            sessions::DEMO_SESSION,
            Uuid::nil(),
            Command::HydrateSession {
                session_id: sessions::DEMO_SESSION,
            },
        )
        .unwrap()
    else {
        panic!("the demo answered a hydrate with something else");
    };
    let session = session.expect("the Demo Session is missing from the fixture");

    assert_eq!(session.messages.len(), 2);
    assert!(!session.transcript_blocks[0].activities.is_empty());

    let ResponsePayload::SessionMessageMatches { matches } = client
        .request(
            Uuid::nil(),
            Uuid::nil(),
            Command::SearchSessionMessages {
                query: "token bucket".into(),
                limit: 10,
            },
        )
        .unwrap()
    else {
        panic!("the demo answered a search with something else");
    };
    assert_eq!(matches[0].session_id, sessions::DEMO_SESSION);
}

#[test]
fn the_first_prompt_streams_the_whole_showcase() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let session_id = sessions::DEMO_SESSION;
    let runtime_id = start(&client, session_id);
    let events = client.subscribe(session_id, runtime_id);

    client
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "Why is the limiter letting too much through?".into(),
            },
        )
        .unwrap();
    let collected = drain(&client, &events, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::TurnFinished { .. })
    });
    let kinds = kinds(&collected);

    for required in [
        "connected",
        "availableCommands",
        "turnStarted",
        "reasoningDelta",
        "textDelta",
        "richActivity",
        "permission",
        "interactionResolved",
        "userInputRequested",
        "backgroundWork",
        "usageUpdated",
        "planUsageUpdated",
        "autoTitleUpdated",
        "turnFinished",
    ] {
        assert!(
            kinds.contains(&required),
            "the stream never carried {required}"
        );
    }
    assert!(
        kinds.iter().filter(|kind| **kind == "textDelta").count() > 20,
        "the assistant text did not arrive as a stream"
    );
    assert!(text(&collected).contains("Continuous refill"));
    assert!(
        matches!(
            shidou_protocol::event_from_wire(collected.last().unwrap().event.clone()).unwrap(),
            DriverEvent::TurnFinished { success: true, .. }
        ),
        "the scripted turn did not settle successfully"
    );
    // Sequence numbers are dense and monotonic, which is what a replay cursor
    // depends on to know it missed nothing.
    let sequences = collected
        .iter()
        .map(|event| event.sequence)
        .collect::<Vec<_>>();
    assert_eq!(
        sequences,
        (sequences[0]..=*sequences.last().unwrap()).collect::<Vec<_>>()
    );
}

#[test]
fn a_reconnecting_client_replays_exactly_the_tail_it_missed() {
    let daemon = Daemon::start();
    let session_id = sessions::DEMO_SESSION;

    let first = daemon.connect();
    let runtime_id = start(&first, session_id);
    let events = first.subscribe(session_id, runtime_id);
    first
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "Why is the limiter letting too much through?".into(),
            },
        )
        .unwrap();

    // Leave partway through, right after the permission is answered.
    let before = drain(&first, &events, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::InteractionResolved { .. })
    });
    // Resume from the last event the projection consumed, not the socket
    // reader's high-water mark. The reader may already have queued later
    // events while this test is deliberately disconnecting mid-stream.
    let last_before = before.last().unwrap();
    let cursor = last_before.sequence;
    let cursors = vec![ReplayCursor {
        session_id,
        runtime_id,
        epoch: last_before.epoch,
        sequence: cursor,
    }];
    first.shutdown();

    let second = daemon.reconnect(cursors);
    let resumed = second.subscribe(session_id, runtime_id);
    let after = drain(&second, &resumed, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::TurnFinished { .. })
    });

    assert_eq!(
        after.first().unwrap().sequence,
        cursor + 1,
        "the replay skipped or repeated an event at the cursor"
    );
    let sequences = after.iter().map(|event| event.sequence).collect::<Vec<_>>();
    assert_eq!(
        sequences,
        (cursor + 1..=*sequences.last().unwrap()).collect::<Vec<_>>()
    );
    assert_eq!(
        after.first().unwrap().epoch,
        before.first().unwrap().epoch,
        "the daemon epoch changed under a live runtime"
    );

    // The two halves together are one whole turn, with nothing duplicated.
    let whole = kinds(&before)
        .into_iter()
        .chain(kinds(&after))
        .collect::<Vec<_>>();
    assert_eq!(
        whole.iter().filter(|kind| **kind == "turnStarted").count(),
        1
    );
    assert_eq!(
        whole.iter().filter(|kind| **kind == "permission").count(),
        1
    );
    assert!(whole.contains(&"userInputRequested"));
    assert!(whole.contains(&"turnFinished"));
}

#[test]
fn a_later_prompt_is_answered_in_the_words_the_reviewer_typed() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let session_id = sessions::DEMO_SESSION;
    let runtime_id = start(&client, session_id);
    let events = client.subscribe(session_id, runtime_id);

    for prompt in [
        "Why is the limiter letting too much through?",
        "Does the composer actually send?",
    ] {
        client
            .request(
                session_id,
                runtime_id,
                Command::Prompt {
                    prompt: prompt.into(),
                },
            )
            .unwrap();
        let turn = drain(&client, &events, session_id, runtime_id, |event| {
            matches!(event, DriverEvent::TurnFinished { .. })
        });
        if prompt.starts_with("Does") {
            assert!(text(&turn).contains("Does the composer actually send?"));
            assert!(text(&turn).contains("demo daemon"));
        }
    }
}

#[test]
fn cancelling_settles_the_turn_instead_of_leaving_it_running() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let session_id = sessions::DEMO_SESSION;
    let runtime_id = start(&client, session_id);
    let events = client.subscribe(session_id, runtime_id);

    client
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "Why is the limiter letting too much through?".into(),
            },
        )
        .unwrap();
    // Wait until the turn is genuinely under way, then interrupt it.
    let deadline = Instant::now() + TURN_DEADLINE;
    while Instant::now() < deadline {
        let event = events.recv_timeout(TURN_DEADLINE).unwrap();
        if event.event.kind == "reasoningDelta" {
            break;
        }
    }
    client
        .request(session_id, runtime_id, Command::Cancel)
        .unwrap();

    let finished = drain(&client, &events, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::TurnFinished { .. })
    });
    assert!(matches!(
        shidou_protocol::event_from_wire(finished.last().unwrap().event.clone()).unwrap(),
        DriverEvent::TurnFinished { success: false, .. }
    ));

    // Cancelling one message must not cancel the one after it.
    client
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "Are you still there?".into(),
            },
        )
        .unwrap();
    let next = drain(&client, &events, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::TurnFinished { .. })
    });
    assert!(matches!(
        shidou_protocol::event_from_wire(next.last().unwrap().event.clone()).unwrap(),
        DriverEvent::TurnFinished { success: true, .. }
    ));
    assert!(text(&next).contains("Are you still there?"));
}

#[test]
fn a_prompt_sent_mid_turn_is_refused_rather_than_interleaved() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let session_id = sessions::DEMO_SESSION;
    let runtime_id = start(&client, session_id);
    let events = client.subscribe(session_id, runtime_id);

    client
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "Why is the limiter letting too much through?".into(),
            },
        )
        .unwrap();
    let error = client
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "And another thing".into(),
            },
        )
        .unwrap_err();
    assert!(error.to_string().contains("still answering"));

    client
        .request(session_id, runtime_id, Command::Cancel)
        .unwrap();
    drain(&client, &events, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::TurnFinished { .. })
    });
    // The refusal released nothing it should not have: the runtime takes the
    // next message once its turn settles.
    assert!(
        client
            .request(
                session_id,
                runtime_id,
                Command::Prompt {
                    prompt: "And another thing".into(),
                },
            )
            .is_ok()
    );
}

#[test]
fn the_workspace_surfaces_answer_without_touching_the_host() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let root = std::path::PathBuf::from(tree::WORKSPACE_ROOT);
    let workspace = |operation| {
        let ResponsePayload::Workspace { result } = client
            .request(Uuid::nil(), Uuid::nil(), Command::Workspace { operation })
            .unwrap()
        else {
            panic!("the demo answered a workspace request with something else");
        };
        result
    };

    let WorkspaceResult::WorkingTree { entries } = workspace(WorkspaceOperation::ListTree {
        root: root.clone(),
        expanded_paths: vec![root.join("src")],
    }) else {
        panic!("unexpected tree result");
    };
    assert!(
        entries
            .iter()
            .any(|entry| entry.relative_path == tree::EDITED_FILE)
    );

    let WorkspaceResult::TextFile { content } = workspace(WorkspaceOperation::ReadTextFile {
        root: root.clone(),
        relative_path: tree::EDITED_FILE.into(),
    }) else {
        panic!("unexpected file result");
    };
    assert!(content.contains("REFILL_PER_SECOND"));

    let WorkspaceResult::CommitSnapshot { snapshot } =
        workspace(WorkspaceOperation::InspectCommit { cwd: root.clone() })
    else {
        panic!("unexpected commit result");
    };
    assert_eq!(snapshot.branch, tree::BRANCH);
    assert!(snapshot.can_push);
    assert_eq!(snapshot.additions, tree::ADDITIONS);

    let WorkspaceResult::ReviewDiff { data } = workspace(WorkspaceOperation::CollectReviewDiff {
        cwd: root.clone(),
        source: ReviewDiffSource::Uncommitted,
    }) else {
        panic!("unexpected diff result");
    };
    assert!(data.patch.contains("@@"));
    assert!(data.complete_context);

    let WorkspaceResult::Directory { path, entries, .. } =
        workspace(WorkspaceOperation::BrowseDirectory { path: None })
    else {
        panic!("unexpected browse result");
    };
    assert_eq!(path, std::path::Path::new(tree::HOME));
    assert!(entries.iter().all(|entry| entry.is_dir));
}

#[test]
fn the_visuals_surface_gets_real_image_bytes_through_the_blob_path() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let root = std::path::PathBuf::from(tree::WORKSPACE_ROOT);

    let ResponsePayload::Workspace {
        result: WorkspaceResult::ProjectFiles { entries },
    } = client
        .request(
            Uuid::nil(),
            Uuid::nil(),
            Command::Workspace {
                operation: WorkspaceOperation::ListProjectFiles {
                    root: root.clone(),
                    cap: 512,
                },
            },
        )
        .unwrap()
    else {
        panic!("the demo answered a file listing with something else");
    };
    let images = entries
        .iter()
        .filter(|entry| !entry.is_dir && entry.path.ends_with(".png"))
        .map(|entry| root.join(&entry.path))
        .collect::<Vec<_>>();
    assert!(
        !images.is_empty(),
        "the demo workspace has no images to show"
    );

    let ResponsePayload::AttachmentsStored { attachments } = client
        .request(
            Uuid::nil(),
            Uuid::nil(),
            Command::ImportPathAttachments {
                paths: images.clone(),
            },
        )
        .unwrap()
    else {
        panic!("the demo answered an import with something else");
    };
    let attachment = attachments[0].clone().expect("the image did not import");

    let ResponsePayload::BlobData { bytes } = client
        .request(
            Uuid::nil(),
            Uuid::nil(),
            Command::ReadAttachment {
                reference: attachment.reference.clone(),
                path: attachment.path.clone(),
            },
        )
        .unwrap()
    else {
        panic!("the demo answered a blob read with something else");
    };
    assert_eq!(&bytes[1..4], b"PNG");
    assert!(!attachment.path.exists(), "the demo must not create files");
}

#[test]
fn the_settings_surfaces_come_back_populated() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let ask = |command| client.request(Uuid::nil(), Uuid::nil(), command).unwrap();

    assert!(matches!(
        ask(Command::GetSettings),
        ResponsePayload::Settings { .. }
    ));

    let ResponsePayload::SkillsCatalog { catalog } = ask(Command::LoadSkills {
        projects: vec![("shidou".into(), tree::WORKSPACE_ROOT.into())],
    }) else {
        panic!("unexpected skills result");
    };
    assert!(!catalog.skills.is_empty());

    let ResponsePayload::UsageHistory { history } = ask(Command::LoadUsageHistory {
        window: shidou_protocol::usage_history::UsageWindow::TrailingDays(30),
        project_roots: vec![tree::WORKSPACE_ROOT.into()],
    }) else {
        panic!("unexpected usage result");
    };
    assert!(history.cost_usd > 0.0);
    assert!(!history.daily.is_empty());

    let ResponsePayload::ProviderProbe { probe, version } = ask(Command::ProbeProvider {
        provider: shidou_protocol::model::ProviderKind::Claude,
        binary_override: None,
        discover_models: true,
        probe_version: true,
    }) else {
        panic!("unexpected probe result");
    };
    assert!(probe.installed);
    assert!(version.is_some());

    let ResponsePayload::PlanUsage { usage } = ask(Command::FetchPlanUsage {
        provider: shidou_protocol::model::ProviderKind::Claude,
        binary_override: None,
        cli_version: None,
    }) else {
        panic!("unexpected plan usage result");
    };
    assert!(!usage.unwrap().windows.is_empty());
}

#[test]
fn commands_with_side_effects_are_refused_with_a_reason() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let root = std::path::PathBuf::from(tree::WORKSPACE_ROOT);

    let commit = client
        .request(
            Uuid::nil(),
            Uuid::nil(),
            Command::Workspace {
                operation: WorkspaceOperation::Commit {
                    cwd: root.clone(),
                    message: "anything".into(),
                    include_unstaged: true,
                    push: true,
                },
            },
        )
        .unwrap_err();
    assert!(commit.to_string().contains("demo"));

    let write = client
        .request(
            Uuid::nil(),
            Uuid::nil(),
            Command::Workspace {
                operation: WorkspaceOperation::WriteTextFile {
                    root,
                    relative_path: tree::EDITED_FILE.into(),
                    content: "overwritten".into(),
                },
            },
        )
        .unwrap_err();
    assert!(write.to_string().contains("read-only"));

    let session_id = Uuid::new_v4();
    let terminal = client
        .request(
            session_id,
            Uuid::new_v4(),
            Command::OpenTerminal {
                cwd: tree::WORKSPACE_ROOT.into(),
                cols: 80,
                rows: 24,
            },
        )
        .unwrap_err();
    assert!(terminal.to_string().contains("no shell"));
}

#[test]
fn a_task_a_client_creates_is_accepted_and_never_stored() {
    let daemon = Daemon::start();
    let client = daemon.connect();
    let session = shidou_protocol::model::AgentSession::new(
        sessions::SHIDOU_PROJECT,
        shidou_protocol::model::ProviderKind::Claude,
    );
    let session_id = session.id;

    let ResponsePayload::TaskStateSaved { sessions: saved } = client
        .request(
            session_id,
            Uuid::nil(),
            Command::SaveTaskState {
                projects: sessions::projects(),
                live_session_ids: vec![session_id],
                sessions: vec![session],
            },
        )
        .unwrap()
    else {
        panic!("the demo answered a save with something else");
    };
    assert_eq!(saved.len(), 1);

    let ResponsePayload::TaskState {
        sessions: listed, ..
    } = client
        .request(Uuid::nil(), Uuid::nil(), Command::LoadTaskState)
        .unwrap()
    else {
        panic!("the demo answered a task-state load with something else");
    };
    assert!(
        !listed.iter().any(|candidate| candidate.id == session_id),
        "the demo persisted a client's task"
    );

    // A brand new task still gets the showcase, so "Try the demo" followed by
    // "new task" is not a dead end.
    let runtime_id = start(&client, session_id);
    let events = client.subscribe(session_id, runtime_id);
    client
        .request(
            session_id,
            runtime_id,
            Command::Prompt {
                prompt: "Show me what you can do.".into(),
            },
        )
        .unwrap();
    let turn = drain(&client, &events, session_id, runtime_id, |event| {
        matches!(event, DriverEvent::TurnFinished { .. })
    });
    assert!(kinds(&turn).contains(&"permission"));
}

#[test]
fn an_unanswered_prompt_releases_itself_rather_than_wedging_the_turn() {
    // The bound is what keeps a backgrounded reviewer from a dead session. It
    // is long in production, so this only asserts the value the player uses.
    assert!(script::INTERACTION_TIMEOUT >= Duration::from_secs(30));
    assert!(script::INTERACTION_TIMEOUT <= Duration::from_secs(300));

    let controls = script::Controls::default();
    controls.resolve(script::PERMISSION_REQUEST);
    assert!(controls.begin_turn().is_some());
}

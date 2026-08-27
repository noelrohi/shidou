//! The Demo Session's scripted turn.
//!
//! A turn is a list of [`Beat`]s: a pure value, so the same prompt always
//! produces the same events in the same order. That is what makes the Demo
//! Session replayable — the daemon's journal holds whatever the player has
//! emitted so far, and a client that reconnects with a replay cursor receives
//! exactly the tail it missed.
//!
//! Timing lives in the player, not in the beats, so the tests below can assert
//! on the whole script without waiting for it.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::time::Duration;

use parking_lot::Mutex;
use shidou_core::EventSink;
use shidou_protocol::model::{
    ActivityItem, ActivityKind, BackgroundWorkEvent, BackgroundWorkItem, BackgroundWorkKind,
    BackgroundWorkStatus, DriverEvent, PermissionOption, ProviderResumeCursor, ReportedCommand,
    UserInputOption, UserInputQuestion,
};
use shidou_protocol::usage::{PlanUsage, PlanWindow};

use crate::sessions;
use crate::tree;

/// The rate the #9 streaming prototype ran at, and the rate this streams at.
const TOKENS_PER_SECOND: f64 = 120.0;
/// Characters per streamed chunk, so a chunk approximates one token.
const CHARS_PER_TOKEN: usize = 4;

/// How long a scripted turn waits for the user to answer a permission or a
/// question before continuing on its own.
///
/// The wait is bounded because a demo nobody answers must not look wedged: a
/// reviewer who backgrounds the app mid-prompt still gets the rest of the
/// turn. Timing out changes when the following beats arrive, never which ones
/// — the event sequence a replay sees is the same either way.
pub const INTERACTION_TIMEOUT: Duration = Duration::from_secs(90);

pub const PERMISSION_REQUEST: &str = "demo-permission-edit-limiter";
pub const QUESTION_REQUEST: &str = "demo-question-rollout";

// A beat is the size of the largest `DriverEvent`. The script is a few dozen
// of them, built once per turn, so boxing would buy nothing but indirection.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug)]
pub enum Beat {
    /// One event, emitted as-is.
    Event(DriverEvent),
    /// Assistant text, streamed a chunk at a time.
    Text(String),
    /// Model reasoning, streamed the same way.
    Reasoning(String),
    /// A beat that reads as work happening rather than instant output.
    Pause(Duration),
    /// Block until the client answers `request_id`, or until the timeout.
    Await { request_id: &'static str },
}

/// The events a freshly started runtime sends before any turn: what a resumed
/// provider process reports about itself.
pub fn handshake() -> Vec<Beat> {
    vec![
        Beat::Event(DriverEvent::Connected {
            provider_cursor: Some(ProviderResumeCursor::Claude {
                session_id: "demo-session".into(),
                resume_at: None,
            }),
        }),
        Beat::Event(DriverEvent::AvailableCommands(
            [
                ("compact", "Summarize the conversation so far"),
                ("review", "Review the working tree"),
                ("changelog", "Draft a changelog entry"),
            ]
            .into_iter()
            .map(|(name, description)| ReportedCommand {
                name: name.to_owned(),
                description: description.to_owned(),
            })
            .collect(),
        )),
        Beat::Event(DriverEvent::UsageUpdated {
            context_tokens: Some(18_420),
            context_window: Some(200_000),
        }),
    ]
}

/// The full showcase: streaming text and reasoning, a tool call with a result,
/// a permission request, a unified diff, a multi-question form, and background
/// work. Played once per runtime, on its first prompt.
pub fn showcase() -> Vec<Beat> {
    vec![
        Beat::Event(DriverEvent::TurnStarted),
        Beat::Reasoning(REASONING.into()),
        Beat::Event(DriverEvent::RichActivity(bash(
            "cargo test -p demo-api limiter",
            None,
            false,
        ))),
        Beat::Pause(Duration::from_millis(900)),
        Beat::Event(DriverEvent::RichActivity(
            bash("cargo test -p demo-api limiter", Some(TEST_FAILURE), true).with_failed(true),
        )),
        Beat::Text(DIAGNOSIS.into()),
        Beat::Event(DriverEvent::Permission {
            request_id: PERMISSION_REQUEST.into(),
            title: format!("Edit {}", tree::EDITED_FILE),
            detail:
                "Replace whole-second refill with continuous refill, and add idle bucket eviction."
                    .into(),
            options: vec![
                PermissionOption {
                    id: "allow-once".into(),
                    label: "Allow once".into(),
                    allow: true,
                },
                PermissionOption {
                    id: "allow-always".into(),
                    label: "Allow for this session".into(),
                    allow: true,
                },
                PermissionOption {
                    id: "reject".into(),
                    label: "Reject".into(),
                    allow: false,
                },
            ],
        }),
        Beat::Await {
            request_id: PERMISSION_REQUEST,
        },
        Beat::Event(DriverEvent::RichActivity(edit())),
        Beat::Event(DriverEvent::BackgroundWork(BackgroundWorkEvent::Upsert(
            watcher(BackgroundWorkStatus::Running, None),
        ))),
        Beat::Text(AFTER_EDIT.into()),
        Beat::Event(DriverEvent::UserInputRequested {
            request_id: QUESTION_REQUEST.into(),
            questions: questions(),
        }),
        Beat::Await {
            request_id: QUESTION_REQUEST,
        },
        Beat::Event(DriverEvent::RichActivity(bash(
            "cargo test -p demo-api limiter",
            None,
            false,
        ))),
        Beat::Pause(Duration::from_millis(700)),
        Beat::Event(DriverEvent::RichActivity(bash(
            "cargo test -p demo-api limiter",
            Some(TEST_SUCCESS),
            true,
        ))),
        Beat::Event(DriverEvent::BackgroundWork(BackgroundWorkEvent::Upsert(
            watcher(BackgroundWorkStatus::Completed, Some(0)),
        ))),
        Beat::Event(DriverEvent::BackgroundWork(BackgroundWorkEvent::Upsert(
            reviewer(),
        ))),
        Beat::Text(SUMMARY.into()),
        Beat::Event(DriverEvent::UsageUpdated {
            context_tokens: Some(24_180),
            context_window: Some(200_000),
        }),
        Beat::Event(DriverEvent::PlanUsageUpdated(PlanUsage {
            plan_label: Some("Demo".into()),
            windows: vec![PlanWindow {
                label: "5-hour".into(),
                percent: 37.0,
                resets_at: Some(sessions::epoch() as i64 + 2 * 60 * 60),
            }],
        })),
        Beat::Event(DriverEvent::AutoTitleUpdated(Some(
            "Continuous refill for the rate limiter".into(),
        ))),
        Beat::Event(DriverEvent::TurnFinished {
            success: true,
            summary: Some("Rewrote the token bucket refill and added idle eviction.".into()),
        }),
    ]
}

/// The reply to anything else typed into the composer.
///
/// It quotes the prompt back so a reviewer can see their own words arrive,
/// then says plainly what the demo is. Nothing about the prompt changes which
/// beats follow.
pub fn canned_reply(prompt: &str) -> Vec<Beat> {
    vec![
        Beat::Event(DriverEvent::TurnStarted),
        Beat::Text(format!(
            "You asked: “{}”\n\n{CANNED_BODY}",
            prompt.trim().replace('\n', " ")
        )),
        Beat::Event(DriverEvent::UsageUpdated {
            context_tokens: Some(24_940),
            context_window: Some(200_000),
        }),
        Beat::Event(DriverEvent::TurnFinished {
            success: true,
            summary: None,
        }),
    ]
}

fn questions() -> Vec<UserInputQuestion> {
    vec![
        UserInputQuestion {
            id: "rollout".into(),
            header: "Rollout".into(),
            question: "Where should the new limiter go first?".into(),
            options: vec![
                UserInputOption {
                    label: "Staging".into(),
                    description: Some("One replica, synthetic traffic only".into()),
                },
                UserInputOption {
                    label: "Production, 10%".into(),
                    description: Some("Behind the existing traffic split".into()),
                },
                UserInputOption {
                    label: "Production, everyone".into(),
                    description: None,
                },
            ],
            multi_select: false,
        },
        UserInputQuestion {
            id: "alerts".into(),
            header: "Alerts".into(),
            question: "Which signals should page on the rollout?".into(),
            options: vec![
                UserInputOption {
                    label: "429 rate".into(),
                    description: Some("Requests refused by the limiter".into()),
                },
                UserInputOption {
                    label: "p99 latency".into(),
                    description: None,
                },
                UserInputOption {
                    label: "Bucket map size".into(),
                    description: Some("Catches eviction regressions".into()),
                },
            ],
            multi_select: true,
        },
    ]
}

fn bash(command: &str, output: Option<&str>, complete: bool) -> ActivityItem {
    ActivityItem {
        display_description: Some("Run the limiter tests".into()),
        ..ActivityItem::new(
            Some("demo-bash-limiter-tests".into()),
            ActivityKind::Command,
            "Bash",
            Some(command.to_owned()),
            complete,
        )
        .with_arguments(Some(serde_json::json!({ "command": command }).to_string()))
        .with_output(output.map(str::to_owned))
    }
}

fn edit() -> ActivityItem {
    ActivityItem {
        file_changes: vec![sessions::limiter_file_change()],
        display_target: Some(tree::EDITED_FILE.into()),
        ..ActivityItem::new(
            Some("demo-edit-limiter".into()),
            ActivityKind::FileChange,
            "Edit",
            Some(tree::EDITED_FILE.into()),
            true,
        )
    }
}

fn watcher(status: BackgroundWorkStatus, exit_code: Option<i32>) -> BackgroundWorkItem {
    BackgroundWorkItem {
        detail: Some("Re-runs the limiter tests on every save".into()),
        command: Some("cargo watch -x 'test -p demo-api limiter'".into()),
        cwd: Some(tree::WORKSPACE_ROOT.into()),
        background: true,
        can_stop: status.is_stoppable(),
        control_id: Some("demo-watch".into()),
        origin_activity_id: Some("demo-bash-limiter-tests".into()),
        exit_code,
        ..BackgroundWorkItem::new(
            BackgroundWorkKind::Process,
            "demo-watch",
            "cargo watch",
            status,
        )
    }
}

fn reviewer() -> BackgroundWorkItem {
    BackgroundWorkItem {
        detail: Some("Reads the diff against the repository's standards".into()),
        role: Some("reviewer".into()),
        model: Some("claude-sonnet-5".into()),
        background: true,
        can_stop: false,
        ..BackgroundWorkItem::new(
            BackgroundWorkKind::Subagent,
            "demo-reviewer",
            "Review the limiter change",
            BackgroundWorkStatus::Completed,
        )
    }
}

/// Splits text the way a provider's stream arrives: a few characters at a
/// time, always breaking after whitespace so no chunk cuts a word in half.
pub fn chunks(text: &str) -> Vec<&str> {
    let mut chunks = Vec::new();
    let mut start = 0;
    let mut since_break = 0;
    for (index, character) in text.char_indices() {
        since_break += 1;
        if since_break >= CHARS_PER_TOKEN && character.is_whitespace() {
            let end = index + character.len_utf8();
            chunks.push(&text[start..end]);
            start = end;
            since_break = 0;
        }
    }
    if start < text.len() {
        chunks.push(&text[start..]);
    }
    chunks
}

/// A runtime's interruption state, shared between the request mailbox and the
/// thread playing its turn.
///
/// A cancel belongs to the turn it interrupted, not to the runtime: cancelling
/// one message must not poison the next one the same session sends.
#[derive(Clone, Default)]
pub struct Controls {
    state: Arc<Mutex<State>>,
}

#[derive(Default)]
struct State {
    /// Increments per turn, so a turn that outlived its cancellation cannot
    /// clear the state of the turn that replaced it.
    generation: u64,
    /// The generation currently playing, if any.
    live: Option<u64>,
    cancelled: bool,
    waiting: HashMap<&'static str, SyncSender<()>>,
}

/// Permission to play one turn. Dropping it frees the runtime for the next.
pub struct Turn {
    controls: Controls,
    generation: u64,
}

impl Controls {
    /// Claims the runtime for one turn, or returns `None` because a turn is
    /// already playing. Two players on one sink would interleave two streams
    /// into a transcript that can only read as one.
    pub fn begin_turn(&self) -> Option<Turn> {
        let mut state = self.state.lock();
        if state.live.is_some() {
            return None;
        }
        state.generation += 1;
        state.cancelled = false;
        state.waiting.clear();
        state.live = Some(state.generation);
        Some(Turn {
            controls: self.clone(),
            generation: state.generation,
        })
    }

    /// Ends the live turn at its next beat and releases whatever it is
    /// blocked on.
    pub fn cancel(&self) {
        let mut state = self.state.lock();
        state.cancelled = true;
        for (_, waiter) in state.waiting.drain() {
            let _ = waiter.try_send(());
        }
    }

    /// Releases a turn blocked on `request_id`. Unknown ids are ignored: a
    /// client may answer a prompt the turn already timed out of.
    pub fn resolve(&self, request_id: &str) {
        if let Some(waiter) = self.state.lock().waiting.remove(request_id) {
            let _ = waiter.try_send(());
        }
    }
}

impl Turn {
    fn is_cancelled(&self) -> bool {
        self.controls.state.lock().cancelled
    }

    /// Arms every wait in `beats` before the first one is emitted.
    ///
    /// A client can answer a permission the instant it arrives, so arming as
    /// each `Await` is reached would leave a window — between emitting the
    /// prompt and blocking on it — in which the answer is dropped and the turn
    /// then waits out its whole timeout for a reply it already had.
    fn arm_all(&self, beats: &[Beat]) -> HashMap<&'static str, Receiver<()>> {
        let mut state = self.controls.state.lock();
        beats
            .iter()
            .filter_map(|beat| match beat {
                Beat::Await { request_id } => {
                    let (sender, receiver) = sync_channel(1);
                    state.waiting.insert(request_id, sender);
                    Some((*request_id, receiver))
                }
                _ => None,
            })
            .collect()
    }

    fn disarm(&self, request_id: &'static str) -> bool {
        self.controls
            .state
            .lock()
            .waiting
            .remove(request_id)
            .is_some()
    }
}

impl Drop for Turn {
    fn drop(&mut self) {
        let mut state = self.controls.state.lock();
        if state.live == Some(self.generation) {
            state.live = None;
            state.waiting.clear();
        }
    }
}

/// Emits beats that nothing can answer or interrupt — the runtime handshake.
pub fn announce(beats: Vec<Beat>, sink: &EventSink) {
    run(beats, sink, None);
}

/// Plays one turn into `sink` at the demo's cadence, freeing the runtime when
/// it ends.
///
/// Runs on its own thread: the runtime mailbox that dispatched the prompt must
/// stay free, or a cancel or a permission answer could not reach the turn it
/// is meant to interrupt.
pub fn play(beats: Vec<Beat>, sink: &EventSink, turn: Turn) {
    run(beats, sink, Some(&turn));
}

fn run(beats: Vec<Beat>, sink: &EventSink, turn: Option<&Turn>) {
    let mut waits = turn.map(|turn| turn.arm_all(&beats)).unwrap_or_default();

    for beat in beats {
        if turn.is_some_and(Turn::is_cancelled) {
            let _ = emit(
                sink,
                DriverEvent::TurnFinished {
                    success: false,
                    summary: None,
                },
            );
            return;
        }
        let played = match beat {
            Beat::Event(event) => emit(sink, event),
            Beat::Text(text) => stream(sink, turn, &text, DriverEvent::TextDelta),
            Beat::Reasoning(text) => stream(sink, turn, &text, DriverEvent::ReasoningDelta),
            Beat::Pause(duration) => {
                std::thread::sleep(duration);
                Ok(())
            }
            Beat::Await { request_id } => match (turn, waits.remove(request_id)) {
                (Some(turn), Some(waiter)) => {
                    let answered = waiter.recv_timeout(INTERACTION_TIMEOUT).is_ok();
                    // Nothing answered, so nothing else will clear the
                    // client's prompt. Retract it before moving on.
                    if !answered && turn.disarm(request_id) {
                        emit(
                            sink,
                            DriverEvent::InteractionResolved {
                                request_id: request_id.to_owned(),
                            },
                        )
                    } else {
                        Ok(())
                    }
                }
                // Nothing can answer an unturned beat, so it is not waited on.
                _ => Ok(()),
            },
        };
        if played.is_err() {
            return;
        }
    }
}

fn stream(
    sink: &EventSink,
    turn: Option<&Turn>,
    text: &str,
    delta: fn(String) -> DriverEvent,
) -> anyhow::Result<()> {
    let interval = Duration::from_secs_f64(1.0 / TOKENS_PER_SECOND);
    for chunk in chunks(text) {
        if turn.is_some_and(Turn::is_cancelled) {
            return Ok(());
        }
        emit(sink, delta(chunk.to_owned()))?;
        std::thread::sleep(interval);
    }
    Ok(())
}

/// Sends one driver event through the daemon's wire encoding.
pub fn emit(sink: &EventSink, event: DriverEvent) -> anyhow::Result<()> {
    sink.send(shidou_protocol::event_to_wire(event)?)
}

const REASONING: &str = "\
The failing assertion is about sustained rate, not about the burst. That points \
at refill rather than at admission: if refill hands back a full bucket on a \
timer, a client that waits out the timer gets the whole burst again, so the \
sustained rate is the burst divided by the interval instead of the rate the \
constant names. I want to see the test output before I say that for certain.";

const DIAGNOSIS: &str = "\
`Bucket::refill` refills in whole-second steps: it returns early until a second \
has passed, then sets `tokens` back to `BURST`. That makes the sustained rate \
20 requests per second — the burst size — rather than the 5 the constant \
promises, and it discards partial refill for any client calling faster than \
once a second.

Continuous refill fixes both: add `elapsed * REFILL_PER_SECOND` tokens and clamp \
at `BURST`. That needs one edit to `src/limiter.rs`.";

const AFTER_EDIT: &str = "\
The edit is in. `refill` now adds tokens proportional to elapsed time and \
clamps at the burst size, and `evict_idle` drops buckets nothing has touched \
recently so the map stops growing with every distinct caller.

Before I run the suite again — a couple of decisions about the rollout.";

const SUMMARY: &str = "\
Tests pass. The change is two things:

1. **Continuous refill.** `refill` adds `elapsed * REFILL_PER_SECOND` tokens \
and clamps at `BURST`, so the sustained rate is the one the constant names.
2. **Idle eviction.** `evict_idle` drops untouched buckets, called from the \
maintenance tick already in `main.rs`.

`demo/rate-limiter` is 11 additions and 6 deletions ahead of `main`, in one \
file. Nothing is committed yet.";

const TEST_FAILURE: &str = "\
running 3 tests
test limiter::tests::bursts_up_to_the_limit ... ok
test limiter::tests::refuses_when_the_bucket_is_empty ... ok
test limiter::tests::sustains_the_configured_rate ... FAILED

failures:

---- limiter::tests::sustains_the_configured_rate stdout ----
assertion `left == right` failed: 10 seconds at 5/s should admit 50 requests
  left: 200
 right: 50

test result: FAILED. 2 passed; 1 failed; 0 ignored";

const TEST_SUCCESS: &str = "\
running 4 tests
test limiter::tests::bursts_up_to_the_limit ... ok
test limiter::tests::evicts_idle_buckets ... ok
test limiter::tests::refuses_when_the_bucket_is_empty ... ok
test limiter::tests::sustains_the_configured_rate ... ok

test result: ok. 4 passed; 0 failed; 0 ignored";

const CANNED_BODY: &str = "\
This is the Shidou **demo daemon**. It serves one scripted session so you can \
see the app work without a Mac running the desktop app: nothing here runs a \
coding agent, executes a command, or touches a file.

Everything you have seen — the streaming above, the tool calls, the diff on \
`src/limiter.rs`, the file tree — is a fixture served over the same protocol a \
real daemon speaks. Pair with your own Mac to run this for real.";

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(beats: &[Beat]) -> Vec<String> {
        beats
            .iter()
            .filter_map(|beat| match beat {
                Beat::Event(event) => {
                    Some(shidou_protocol::event_to_wire(event.clone()).unwrap().kind)
                }
                Beat::Text(_) => Some("textDelta".into()),
                Beat::Reasoning(_) => Some("reasoningDelta".into()),
                Beat::Pause(_) => None,
                Beat::Await { .. } => None,
            })
            .collect()
    }

    #[test]
    fn the_showcase_covers_every_surface_the_demo_promises() {
        let kinds = kinds(&showcase());

        for required in [
            "turnStarted",
            "reasoningDelta",
            "textDelta",
            "richActivity",
            "permission",
            "userInputRequested",
            "backgroundWork",
            "usageUpdated",
            "planUsageUpdated",
            "autoTitleUpdated",
            "turnFinished",
        ] {
            assert!(
                kinds.iter().any(|kind| kind == required),
                "missing {required}"
            );
        }
    }

    #[test]
    fn the_showcase_carries_a_unified_diff_for_the_edited_file() {
        let diff = showcase()
            .into_iter()
            .filter_map(|beat| match beat {
                Beat::Event(DriverEvent::RichActivity(activity)) => Some(activity),
                _ => None,
            })
            .flat_map(|activity| activity.file_changes)
            .find(|change| change.path == tree::EDITED_FILE)
            .expect("the showcase never edits the limiter");

        assert!(diff.diff.as_deref().is_some_and(|diff| diff.contains("@@")));
        assert_eq!(diff.additions, Some(tree::ADDITIONS));
    }

    #[test]
    fn the_tool_call_reports_a_result_after_it_reports_the_command() {
        let activities = showcase()
            .into_iter()
            .filter_map(|beat| match beat {
                Beat::Event(DriverEvent::RichActivity(activity)) => Some(activity),
                _ => None,
            })
            .filter(|activity| activity.kind == ActivityKind::Command)
            .collect::<Vec<_>>();

        assert!(activities[0].output.is_none() && !activities[0].complete);
        assert!(activities[1].output.is_some() && activities[1].complete);
        assert!(activities[1].failed, "the first run is the failing one");
        assert!(
            activities
                .iter()
                .all(|activity| activity.source_id.as_deref() == Some("demo-bash-limiter-tests")),
            "a result must update the call it belongs to"
        );
    }

    #[test]
    fn the_permission_offers_a_way_to_allow_and_a_way_to_refuse() {
        let Some(Beat::Event(DriverEvent::Permission { options, .. })) = showcase()
            .into_iter()
            .find(|beat| matches!(beat, Beat::Event(DriverEvent::Permission { .. })))
        else {
            panic!("the showcase never asks permission");
        };

        assert!(options.iter().any(|option| option.allow));
        assert!(options.iter().any(|option| !option.allow));
    }

    #[test]
    fn the_question_form_asks_more_than_one_question_and_offers_multi_select() {
        let questions = questions();

        assert!(questions.len() > 1);
        assert!(questions.iter().any(|question| question.multi_select));
        assert!(
            questions
                .iter()
                .all(|question| !question.options.is_empty())
        );
    }

    #[test]
    fn every_blocking_prompt_is_awaited_after_it_is_asked() {
        let beats = showcase();
        let position = |predicate: fn(&Beat) -> bool| {
            beats.iter().position(predicate).expect("beat is missing")
        };

        assert!(
            position(|beat| matches!(beat, Beat::Event(DriverEvent::Permission { .. })))
                < position(|beat| matches!(
                    beat,
                    Beat::Await {
                        request_id: PERMISSION_REQUEST
                    }
                ))
        );
        assert!(
            position(|beat| matches!(beat, Beat::Event(DriverEvent::UserInputRequested { .. })))
                < position(|beat| matches!(
                    beat,
                    Beat::Await {
                        request_id: QUESTION_REQUEST
                    }
                ))
        );
    }

    #[test]
    fn the_script_is_the_same_every_time_it_is_built() {
        assert_eq!(kinds(&showcase()), kinds(&showcase()));
        assert_eq!(kinds(&canned_reply("hello")), kinds(&canned_reply("other")));
        assert_eq!(
            kinds(&handshake()),
            ["connected", "availableCommands", "usageUpdated"]
        );
    }

    #[test]
    fn every_scripted_event_survives_the_wire_round_trip() {
        for beat in handshake().into_iter().chain(showcase()) {
            let Beat::Event(event) = beat else { continue };
            let wire = shidou_protocol::event_to_wire(event).unwrap();
            shidou_protocol::event_from_wire(wire).expect("the client cannot decode this event");
        }
    }

    #[test]
    fn the_canned_reply_quotes_the_prompt_back() {
        let Some(Beat::Text(text)) = canned_reply("does the composer work?")
            .into_iter()
            .find(|beat| matches!(beat, Beat::Text(_)))
        else {
            panic!("the canned reply says nothing");
        };

        assert!(text.contains("does the composer work?"));
        assert!(text.contains("demo daemon"));
    }

    #[test]
    fn chunking_preserves_the_text_and_breaks_on_word_boundaries() {
        let text = "The quick brown fox\njumps over the lazy dog.";
        let chunks = chunks(text);

        assert_eq!(chunks.concat(), text);
        assert!(chunks.len() > 1);
        assert!(
            chunks[..chunks.len() - 1]
                .iter()
                .all(|chunk| chunk.ends_with(char::is_whitespace))
        );
    }

    #[test]
    fn chunking_handles_text_with_no_break_in_it() {
        assert_eq!(chunks("supercalifragilistic"), ["supercalifragilistic"]);
        assert_eq!(chunks(""), Vec::<&str>::new());
    }

    #[test]
    fn a_streamed_showcase_stays_well_inside_the_replay_journal() {
        let events = showcase()
            .iter()
            .map(|beat| match beat {
                Beat::Text(text) | Beat::Reasoning(text) => chunks(text).len(),
                Beat::Pause(_) | Beat::Await { .. } => 0,
                Beat::Event(_) => 1,
            })
            .sum::<usize>();

        // `MAX_REPLAY_EVENTS_PER_SESSION` in the daemon is 4096; a turn that
        // overran it would drop its own opening from any replay.
        assert!(events < 2_000, "the showcase emits {events} events");
    }

    #[test]
    fn cancelling_releases_a_turn_waiting_on_an_answer() {
        let controls = Controls::default();
        let turn = controls.begin_turn().unwrap();
        let waits = turn.arm_all(&showcase());

        controls.cancel();

        assert!(turn.is_cancelled());
        assert!(
            waits[PERMISSION_REQUEST]
                .recv_timeout(Duration::from_secs(1))
                .is_ok()
        );
    }

    #[test]
    fn answering_releases_only_the_prompt_that_was_answered() {
        let controls = Controls::default();
        let turn = controls.begin_turn().unwrap();
        let waits = turn.arm_all(&showcase());

        controls.resolve(PERMISSION_REQUEST);

        assert!(
            waits[PERMISSION_REQUEST]
                .recv_timeout(Duration::from_secs(1))
                .is_ok()
        );
        assert!(waits[QUESTION_REQUEST].try_recv().is_err());
        controls.resolve("a request nothing is waiting on");
    }

    /// The whole point of arming up front: an answer that beats the turn to
    /// its own `Await` is still there when the turn gets to it.
    #[test]
    fn an_answer_that_arrives_early_is_waiting_when_the_turn_blocks() {
        let controls = Controls::default();
        let turn = controls.begin_turn().unwrap();
        let waits = turn.arm_all(&showcase());

        controls.resolve(PERMISSION_REQUEST);

        assert!(waits[PERMISSION_REQUEST].try_recv().is_ok());
    }

    #[test]
    fn cancelling_one_turn_does_not_poison_the_next() {
        let controls = Controls::default();
        let first = controls.begin_turn().unwrap();
        controls.cancel();
        assert!(first.is_cancelled());
        drop(first);

        let second = controls.begin_turn().expect("the runtime stayed claimed");
        assert!(
            !second.is_cancelled(),
            "a cancelled message must not cancel the one after it"
        );
    }

    #[test]
    fn a_runtime_plays_one_turn_at_a_time() {
        let controls = Controls::default();
        let turn = controls.begin_turn().unwrap();

        assert!(
            controls.begin_turn().is_none(),
            "two players on one sink would interleave two streams"
        );
        drop(turn);
        assert!(controls.begin_turn().is_some());
    }

    /// A turn that outlived its own cancellation must not free a runtime the
    /// next turn already claimed.
    #[test]
    fn a_stale_turn_does_not_release_its_successor() {
        let controls = Controls::default();
        let stale = controls.begin_turn().unwrap();
        let generation = stale.generation;
        std::mem::forget(stale);

        let live = controls.begin_turn();
        assert!(live.is_none(), "the runtime is still claimed");
        controls.state.lock().live = Some(generation + 1);
        drop(Turn {
            controls: controls.clone(),
            generation,
        });

        assert_eq!(controls.state.lock().live, Some(generation + 1));
    }
}

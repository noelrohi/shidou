//! The canonical Reducer: the fold from runtime driver events onto a
//! session's Projection — its messages, turns, transcript blocks, provider
//! cursor, and status.
//!
//! The daemon reduces the live stream with this exact fold to author the
//! persisted transcript, and the desktop app delegates its event handling
//! here, so the daemon's record and the desktop's live view cannot diverge.
//! The web and iOS clients keep byte-faithful ports of this logic for live
//! rendering; this module's tests define the contract those ports must match.
//!
//! Events that touch only host-owned state — background work, computer-use
//! previews, plan-usage meters, steer-rejection fallback policy — are
//! deliberately no-ops here: they are not part of the Projection.

use uuid::Uuid;

use crate::model::{
    ActivityItem, AgentSession, AgentTurn, ContextUsage, DriverEvent, Message, MessageAttachment,
    MessageRole, ProviderResumeCursor, ReasoningBlock, SessionStatus, TranscriptBlock, TurnStatus,
    unix_time, unix_time_millis,
};

/// What kind of output the stream most recently produced. Deltas of one kind
/// coalesce into the same message or activity while the phase holds; a phase
/// change closes the previous run (finishing a streaming message, completing
/// a reasoning activity) before the next one opens.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StreamPhase {
    Text,
    Reasoning,
    Activity,
}

/// Per-runtime fold state that is not part of the persisted Projection: the
/// stream phase and the request ids of blocking interactions awaiting a
/// response. One value lives beside each attached runtime and is reset when
/// the runtime's stream is detached or rewound.
#[derive(Debug, Default)]
pub struct Reducer {
    stream_phase: Option<StreamPhase>,
    pending_permission: Option<String>,
    pending_user_input: Option<String>,
}

/// Plain-data inputs a host resolves from its own state before folding one
/// event. The daemon uses `Default` throughout; the desktop fills the fields
/// its richer runtime state can answer.
#[derive(Debug, Default)]
pub struct ReduceContext {
    /// Refuse turn output even when the session would accept it. The desktop
    /// sets this while a submission is still preparing, when a reused runtime
    /// could only be draining leftovers of a settled turn.
    pub suppress_turn_output: bool,
    /// Presentation metadata for an accepted steering message, resolved by
    /// the host from its pending-steer queue. `None` renders the provider's
    /// echoed text as a plain message.
    pub steer_presentation: Option<SteerPresentation>,
    /// The last driver error, shown when the process exits before responding.
    pub process_exit_error: Option<String>,
}

#[derive(Debug, Default)]
pub struct SteerPresentation {
    pub display_content: Option<String>,
    pub attachments: Vec<MessageAttachment>,
}

/// What one fold step did to the Projection, for hosts that layer side
/// effects (persistence, notifications, caches) on top of it.
#[derive(Debug, Default)]
pub struct Reduction {
    /// The event mutated the session. For gated turn output this is the gate
    /// verdict: a delta or activity dropped outside a running turn reports
    /// `false`.
    pub applied: bool,
    /// The provider reported a different slash-command set.
    pub commands_changed: bool,
    /// An existing activity's file changes were replaced, so anything built
    /// from the previous rows (an expanded diff card) must be rebuilt.
    pub replaced_activity_diff: Option<Uuid>,
    /// A running turn settled during this step.
    pub finished_turn: Option<FinishedTurn>,
}

#[derive(Clone, Copy, Debug)]
pub struct FinishedTurn {
    pub turn_id: Uuid,
    pub turn_count: usize,
    pub status: TurnStatus,
}

impl Reducer {
    pub fn stream_phase(&self) -> Option<StreamPhase> {
        self.stream_phase
    }

    /// Forget transient fold state — the stream phase and pending
    /// interactions — when the host detaches, rewinds, or replaces the
    /// runtime's stream.
    pub fn reset(&mut self) {
        self.stream_phase = None;
        self.pending_permission = None;
        self.pending_user_input = None;
    }

    /// Fold one driver event onto the session's Projection.
    pub fn apply(
        &mut self,
        session: &mut AgentSession,
        event: DriverEvent,
        ctx: ReduceContext,
    ) -> Reduction {
        let mut reduction = Reduction::default();
        match event {
            DriverEvent::RuntimeEventCursorAdvanced(cursor) => {
                session.runtime_event_cursor = Some(cursor);
                reduction.applied = true;
            }
            DriverEvent::Connected { provider_cursor } => {
                if let Some(ProviderResumeCursor::Claude {
                    resume_at: Some(message_id),
                    ..
                }) = &provider_cursor
                {
                    session.mark_active_turn_provider_resume_at(message_id.clone());
                }
                session.provider_cursor = provider_cursor;
                if session.status == SessionStatus::Connecting {
                    session.status = SessionStatus::Working;
                }
                reduction.applied = true;
            }
            DriverEvent::AgentPresetSelected(agent_preset) => {
                session.agent_preset = agent_preset;
                reduction.applied = true;
            }
            DriverEvent::AutoTitleUpdated(title) => {
                reduction.applied = session.set_auto_title(title);
            }
            DriverEvent::AvailableCommands(names) => {
                if session.available_commands != names {
                    session.available_commands = names;
                    reduction.commands_changed = true;
                    reduction.applied = true;
                }
            }
            DriverEvent::TurnAccepted { turn, messages } => {
                accept_remote_turn(session, turn, messages);
                reduction.applied = true;
            }
            DriverEvent::TurnStarted => {
                if session.active_turn_id().is_some() {
                    session.mark_active_turn_provider_started();
                    session.status = SessionStatus::Working;
                    reduction.applied = true;
                }
            }
            DriverEvent::TextDelta(delta) => {
                if self.accepts_turn_output(session, &ctx) {
                    self.append_text_delta(session, delta);
                    reduction.applied = true;
                }
            }
            DriverEvent::ReasoningDelta(delta) => {
                if self.accepts_turn_output(session, &ctx) {
                    self.append_reasoning_delta(session, delta);
                    reduction.applied = true;
                }
            }
            DriverEvent::Activity {
                id,
                kind,
                title,
                detail,
                complete,
            } => {
                let item = ActivityItem::new(id, kind, title, detail, complete);
                self.apply_activity(session, item, &ctx, &mut reduction);
            }
            DriverEvent::RichActivity(item) => {
                self.apply_activity(session, item, &ctx, &mut reduction);
            }
            DriverEvent::Permission { request_id, .. } => {
                if self.accepts_turn_output(session, &ctx) {
                    self.pending_permission = Some(request_id);
                    session.status = SessionStatus::Waiting;
                    reduction.applied = true;
                }
            }
            DriverEvent::UserInputRequested {
                request_id,
                questions,
            } => {
                if self.accepts_turn_output(session, &ctx) && !questions.is_empty() {
                    self.pending_user_input = Some(request_id);
                    session.status = SessionStatus::Waiting;
                    reduction.applied = true;
                }
            }
            DriverEvent::InteractionResolved { request_id } => {
                let permission_matches =
                    self.pending_permission.as_deref() == Some(request_id.as_str());
                let user_input_matches =
                    self.pending_user_input.as_deref() == Some(request_id.as_str());
                if permission_matches {
                    self.pending_permission = None;
                }
                if user_input_matches {
                    self.pending_user_input = None;
                }
                if permission_matches || user_input_matches {
                    session.status = SessionStatus::Working;
                    reduction.applied = true;
                }
            }
            DriverEvent::SteerAccepted { message } => {
                // The provider folded the message into the live turn. Append
                // it to the same turn so the transcript mirrors the provider
                // conversation (no new turn boundary).
                let presentation = ctx.steer_presentation.unwrap_or_default();
                session.push_user_message_with_presentation(
                    message,
                    presentation.display_content,
                    presentation.attachments,
                );
                session.updated_at = unix_time();
                reduction.applied = true;
            }
            DriverEvent::UsageUpdated {
                context_tokens,
                context_window,
            } => {
                // Meta about the conversation, not turn output: it applies
                // even while a rewound or cancelled turn's tail drains.
                let usage = session.context_usage.get_or_insert(ContextUsage::default());
                if let Some(tokens) = context_tokens {
                    usage.tokens = tokens;
                }
                if let Some(window) = context_window {
                    usage.window = Some(window);
                }
                reduction.applied = true;
            }
            DriverEvent::TurnFinished { success, summary } => {
                if session.active_turn_id().is_none() {
                    return reduction;
                }
                finish_streaming_assistant(session);
                complete_turn_blocks(session);
                self.reset();
                let needs_fallback = !active_turn_has_assistant_message(session);
                session.status = if success {
                    SessionStatus::Idle
                } else {
                    SessionStatus::Failed
                };
                if needs_fallback {
                    session.push_message(
                        MessageRole::Assistant,
                        summary.unwrap_or_else(|| {
                            if success {
                                tr!("session.turn_completed")
                            } else {
                                tr!("session.stopped_before_response")
                            }
                        }),
                    );
                }
                let status = if success {
                    TurnStatus::Completed
                } else {
                    TurnStatus::Failed
                };
                reduction.finished_turn =
                    session
                        .finish_active_turn(status)
                        .map(|(turn_id, turn_count)| FinishedTurn {
                            turn_id,
                            turn_count,
                            status,
                        });
                reduction.applied = true;
            }
            DriverEvent::Error(error) => {
                let error = compact_driver_error(&error);
                let has_active_turn = session.active_turn_id().is_some();
                let should_append = has_active_turn
                    && !active_turn_has_assistant_message(session)
                    && session.status != SessionStatus::Working;
                if has_active_turn {
                    if session.status != SessionStatus::Working {
                        session.status = SessionStatus::Failed;
                    }
                    if should_append {
                        session.push_message(MessageRole::Assistant, error);
                    }
                    reduction.applied = true;
                }
            }
            DriverEvent::ProcessExited => {
                finish_streaming_assistant(session);
                complete_turn_blocks(session);
                self.reset();
                let needs_fallback = !active_turn_has_assistant_message(session);
                let failure_message = ctx
                    .process_exit_error
                    .unwrap_or_else(|| tr!("session.codex_exited_before_response"));
                if matches!(
                    session.status,
                    SessionStatus::Connecting | SessionStatus::Working | SessionStatus::Waiting
                ) {
                    session.status = SessionStatus::Failed;
                    session.updated_at = unix_time();
                    if needs_fallback {
                        session.push_message(MessageRole::Assistant, failure_message);
                    }
                    reduction.finished_turn = session.finish_active_turn(TurnStatus::Failed).map(
                        |(turn_id, turn_count)| FinishedTurn {
                            turn_id,
                            turn_count,
                            status: TurnStatus::Failed,
                        },
                    );
                    reduction.applied = true;
                }
            }
            // Host-owned state, outside the Projection.
            DriverEvent::BackgroundWork(_)
            | DriverEvent::ComputerUseUpdated(_)
            | DriverEvent::SteerRejected { .. }
            | DriverEvent::PlanUsageUpdated(_) => {}
        }
        reduction
    }

    fn accepts_turn_output(&self, session: &mut AgentSession, ctx: &ReduceContext) -> bool {
        !ctx.suppress_turn_output && session_accepts_turn_output(session)
    }

    fn append_text_delta(&mut self, session: &mut AgentSession, delta: String) {
        let previous_phase = self.stream_phase;
        if previous_phase == Some(StreamPhase::Reasoning) {
            complete_reasoning_activity(session);
        }
        let continuing = previous_phase == Some(StreamPhase::Text);
        let id = session.id;
        append_text_delta_to_session(std::slice::from_mut(session), id, continuing, delta);
        self.stream_phase = Some(StreamPhase::Text);
    }

    fn append_reasoning_delta(&mut self, session: &mut AgentSession, delta: String) {
        let previous_phase = self.stream_phase;
        let continuing = previous_phase == Some(StreamPhase::Reasoning);
        if !continuing && delta.trim().is_empty() {
            return;
        }
        let now = unix_time_millis();
        if !continuing {
            finish_streaming_assistant(session);
        }
        if continuing
            && let Some(reasoning) = session
                .transcript_blocks
                .last_mut()
                .and_then(|block| block.activities.last_mut())
                .and_then(|activity| activity.reasoning.as_mut())
        {
            reasoning.content.push_str(&delta);
            reasoning.finished_at_ms = now;
        } else {
            push_transcript_activity(
                session,
                ActivityItem::from_reasoning(
                    ReasoningBlock {
                        content: delta,
                        started_at_ms: now,
                        finished_at_ms: now,
                    },
                    false,
                ),
                matches!(
                    previous_phase,
                    Some(StreamPhase::Reasoning | StreamPhase::Activity)
                ),
            );
        }
        session.updated_at = unix_time();
        self.stream_phase = Some(StreamPhase::Reasoning);
    }

    fn apply_activity(
        &mut self,
        session: &mut AgentSession,
        item: ActivityItem,
        ctx: &ReduceContext,
        reduction: &mut Reduction,
    ) {
        if !self.accepts_turn_output(session, ctx) {
            return;
        }
        reduction.applied = true;
        let previous_phase = self.stream_phase;
        if previous_phase == Some(StreamPhase::Text) {
            finish_streaming_assistant(session);
        }
        if previous_phase == Some(StreamPhase::Reasoning) {
            complete_reasoning_activity(session);
        }

        let continuing_work = matches!(
            previous_phase,
            Some(StreamPhase::Reasoning | StreamPhase::Activity)
        );
        self.stream_phase = Some(StreamPhase::Activity);
        for block in session.transcript_blocks.iter_mut().rev() {
            let matching = block.activities.iter_mut().rev().find(|activity| {
                item.source_id
                    .as_ref()
                    .is_some_and(|id| activity.source_id.as_ref() == Some(id))
                    || (item.source_id.is_none()
                        && activity.title == item.title
                        && !activity.complete)
            });
            if let Some(activity) = matching {
                let has_arguments = item.arguments.is_some();
                let replaces_changes = !item.file_changes.is_empty();
                if replaces_changes {
                    // The rows this activity's diff was built from are gone;
                    // anything expanded from them must rebuild from the new
                    // ones.
                    reduction.replaced_activity_diff = Some(activity.id);
                }
                activity.kind = item.kind;
                activity.title = item.title;
                activity.complete = item.complete;
                activity.failed = item.failed;
                if item.detail.is_some() {
                    activity.detail = item.detail;
                }
                if item.arguments.is_some() {
                    activity.arguments = item.arguments;
                }
                if item.output.is_some() {
                    activity.output = item.output;
                }
                if !item.image_urls.is_empty() {
                    activity.image_urls = item.image_urls;
                }
                if !item.file_changes.is_empty() {
                    activity.file_changes = item.file_changes;
                }
                if item.display_target.is_some()
                    && (activity.display_target.is_none() || has_arguments)
                {
                    activity.display_target = item.display_target;
                }
                if item.display_description.is_some()
                    && (activity.display_description.is_none() || has_arguments)
                {
                    activity.display_description = item.display_description;
                }
                if item.reasoning.is_some() {
                    activity.reasoning = item.reasoning;
                }
                session.updated_at = unix_time();
                return;
            }
        }

        push_transcript_activity(session, item, continuing_work);
        session.updated_at = unix_time();
    }
}

/// Incorporate the turn another client persisted before it prompted the
/// shared runtime. IDs come from the daemon's canonical projection, so source
/// clients no-op while observers gain the exact turn needed to reduce the
/// provider events that follow.
pub fn accept_remote_turn(session: &mut AgentSession, turn: AgentTurn, messages: Vec<Message>) {
    let known_turn = session.turns.iter().any(|existing| existing.id == turn.id);
    for message in messages {
        if !session
            .messages
            .iter()
            .any(|existing| existing.id == message.id)
        {
            session.messages.push(message);
        }
    }
    session.updated_at = session.updated_at.max(turn.started_at);
    if turn.status == TurnStatus::Running && !session.status.is_busy() {
        session.status = SessionStatus::Connecting;
    }
    if known_turn {
        return;
    }
    session.turns.push(turn);
}

/// Foreground output is stronger evidence of a started provider turn than a
/// replayed lifecycle cursor. Repair both pieces of transient state here so a
/// runtime attachment that missed `TurnStarted` cannot leave the session
/// refusing output it is visibly receiving.
pub fn session_accepts_turn_output(session: &mut AgentSession) -> bool {
    if session.active_turn_id().is_none()
        || !matches!(
            session.status,
            SessionStatus::Connecting | SessionStatus::Working | SessionStatus::Waiting
        )
    {
        return false;
    }
    session.mark_active_turn_provider_started();
    if session.status == SessionStatus::Connecting {
        session.status = SessionStatus::Working;
    }
    true
}

pub fn finish_streaming_assistant(session: &mut AgentSession) {
    for message in &mut session.messages {
        if message.role == MessageRole::Assistant && message.streaming {
            message.streaming = false;
        }
    }
}

pub fn complete_turn_blocks(session: &mut AgentSession) {
    for block in &mut session.transcript_blocks {
        for activity in &mut block.activities {
            activity.complete = true;
        }
    }
}

pub fn active_turn_has_assistant_message(session: &AgentSession) -> bool {
    let Some(turn_id) = session.active_turn_id() else {
        return false;
    };
    session
        .messages
        .iter()
        .any(|message| message.role == MessageRole::Assistant && message.turn_id == Some(turn_id))
}

fn complete_reasoning_activity(session: &mut AgentSession) {
    let reasoning = session
        .transcript_blocks
        .iter_mut()
        .rev()
        .flat_map(|block| block.activities.iter_mut().rev())
        .find(|activity| activity.reasoning.is_some() && !activity.complete);
    if let Some(reasoning) = reasoning {
        reasoning.complete = true;
        session.updated_at = unix_time();
    }
}

pub fn push_transcript_activity(
    session: &mut AgentSession,
    item: ActivityItem,
    continuing_work: bool,
) {
    let after_message = session.messages.len();
    let turn_id = session.active_turn_id();
    if continuing_work
        && let Some(block) = session.transcript_blocks.last_mut()
        && block.after_message == after_message
        && block.turn_id == turn_id
    {
        block.activities.push(item);
    } else {
        session.transcript_blocks.push(TranscriptBlock {
            after_message,
            turn_id,
            activities: vec![item],
        });
    }
}

pub fn append_text_delta_to_session(
    sessions: &mut [AgentSession],
    session_id: Uuid,
    continuing: bool,
    delta: String,
) {
    let Some(session) = sessions.iter_mut().find(|session| session.id == session_id) else {
        return;
    };
    if !continuing {
        finish_streaming_assistant(session);
    }
    let existing = continuing.then(|| {
        session
            .messages
            .iter_mut()
            .rev()
            .find(|message| message.role == MessageRole::Assistant && message.streaming)
    });
    if let Some(Some(message)) = existing {
        message.content.push_str(&delta);
    } else {
        let mut message = session
            .active_turn_id()
            .map(|turn_id| Message::new_for_turn(MessageRole::Assistant, delta.clone(), turn_id))
            .unwrap_or_else(|| Message::new(MessageRole::Assistant, delta));
        message.streaming = true;
        session.messages.push(message);
    }
    session.updated_at = unix_time();
}

pub fn compact_driver_error(error: &str) -> String {
    const MAX_LINES: usize = 6;
    const MAX_CHARS: usize = 800;

    let lines = error.lines().collect::<Vec<_>>();
    let mut compact = lines
        .iter()
        .take(MAX_LINES)
        .copied()
        .collect::<Vec<_>>()
        .join("\n");
    if lines.len() > MAX_LINES {
        compact.push_str("\n…");
    }
    if compact.chars().count() > MAX_CHARS {
        compact = compact.chars().take(MAX_CHARS - 1).collect();
        compact.push('…');
    }
    compact
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ActivityKind, ProviderKind, RuntimeEventCursor};

    fn session_with_running_turn() -> (AgentSession, Uuid) {
        let mut session = AgentSession::new(Uuid::new_v4(), ProviderKind::Claude);
        let turn_id = session.begin_turn("do the thing");
        session.status = SessionStatus::Connecting;
        (session, turn_id)
    }

    fn apply(
        reducer: &mut Reducer,
        session: &mut AgentSession,
        events: impl IntoIterator<Item = DriverEvent>,
    ) {
        for event in events {
            reducer.apply(session, event, ReduceContext::default());
        }
    }

    #[test]
    fn turn_lifecycle_produces_completed_projection() {
        let (mut session, turn_id) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::TurnStarted,
                DriverEvent::ReasoningDelta("thinking".into()),
                DriverEvent::RichActivity(ActivityItem::new(
                    Some("tool-1".into()),
                    ActivityKind::Command,
                    "Run tests",
                    None,
                    false,
                )),
                DriverEvent::TextDelta("All ".into()),
                DriverEvent::TextDelta("done.".into()),
                DriverEvent::TurnFinished {
                    success: true,
                    summary: None,
                },
            ],
        );

        assert_eq!(session.status, SessionStatus::Idle);
        let turn = session.turns.last().unwrap();
        assert_eq!(turn.id, turn_id);
        assert_eq!(turn.status, TurnStatus::Completed);
        assert!(turn.provider_turn_started);
        assert!(turn.completed_at.is_some());

        let assistant = session
            .messages
            .iter()
            .find(|message| message.role == MessageRole::Assistant)
            .unwrap();
        assert_eq!(assistant.content, "All done.");
        assert_eq!(assistant.turn_id, Some(turn_id));
        assert!(!assistant.streaming);

        let activities = session
            .transcript_blocks
            .iter()
            .flat_map(|block| &block.activities)
            .collect::<Vec<_>>();
        assert_eq!(activities.len(), 2);
        assert!(activities[0].reasoning.is_some());
        assert!(activities.iter().all(|activity| activity.complete));
        assert_eq!(session.last_reply_at, turn.completed_at);
    }

    #[test]
    fn adjacent_text_deltas_extend_one_streaming_message() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::TextDelta("first".into()),
                DriverEvent::TextDelta(" second".into()),
            ],
        );

        let assistants = session
            .messages
            .iter()
            .filter(|message| message.role == MessageRole::Assistant)
            .collect::<Vec<_>>();
        assert_eq!(assistants.len(), 1);
        assert_eq!(assistants[0].content, "first second");
        assert!(assistants[0].streaming);

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::RichActivity(ActivityItem::new(
                    None,
                    ActivityKind::Tool,
                    "Lookup",
                    None,
                    true,
                )),
                DriverEvent::TextDelta("third".into()),
            ],
        );

        let assistants = session
            .messages
            .iter()
            .filter(|message| message.role == MessageRole::Assistant)
            .collect::<Vec<_>>();
        assert_eq!(assistants.len(), 2, "an activity closes the streaming run");
        assert!(!assistants[0].streaming);
        assert_eq!(assistants[1].content, "third");
    }

    #[test]
    fn turn_output_is_dropped_without_a_running_turn() {
        let mut session = AgentSession::new(Uuid::new_v4(), ProviderKind::Claude);
        let mut reducer = Reducer::default();

        let reduction = reducer.apply(
            &mut session,
            DriverEvent::TextDelta("stray".into()),
            ReduceContext::default(),
        );

        assert!(!reduction.applied);
        assert!(session.messages.is_empty());
        assert!(session.transcript_blocks.is_empty());
    }

    #[test]
    fn suppressed_turn_output_is_dropped() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        let reduction = reducer.apply(
            &mut session,
            DriverEvent::TextDelta("stale".into()),
            ReduceContext {
                suppress_turn_output: true,
                ..ReduceContext::default()
            },
        );

        assert!(!reduction.applied);
        assert!(
            session
                .messages
                .iter()
                .all(|message| message.role != MessageRole::Assistant)
        );
    }

    #[test]
    fn connected_records_provider_cursor_and_resume_position() {
        let (mut session, turn_id) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [DriverEvent::Connected {
                provider_cursor: Some(ProviderResumeCursor::Claude {
                    session_id: "native-1".into(),
                    resume_at: Some("msg-9".into()),
                }),
            }],
        );

        assert_eq!(session.status, SessionStatus::Working);
        assert!(matches!(
            &session.provider_cursor,
            Some(ProviderResumeCursor::Claude { session_id, resume_at })
                if session_id == "native-1" && resume_at.as_deref() == Some("msg-9")
        ));
        let turn = session
            .turns
            .iter()
            .find(|turn| turn.id == turn_id)
            .unwrap();
        assert_eq!(turn.provider_resume_at.as_deref(), Some("msg-9"));
    }

    #[test]
    fn refreshed_connected_cursor_replaces_a_forked_native_session() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::Connected {
                    provider_cursor: Some(ProviderResumeCursor::Claude {
                        session_id: "before-clear".into(),
                        resume_at: None,
                    }),
                },
                DriverEvent::Connected {
                    provider_cursor: Some(ProviderResumeCursor::Claude {
                        session_id: "after-clear".into(),
                        resume_at: None,
                    }),
                },
            ],
        );

        assert!(matches!(
            &session.provider_cursor,
            Some(ProviderResumeCursor::Claude { session_id, .. }) if session_id == "after-clear"
        ));
    }

    #[test]
    fn runtime_event_cursor_advances() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();
        let cursor = RuntimeEventCursor {
            runtime_id: Uuid::new_v4(),
            epoch: Uuid::new_v4(),
            sequence: 41,
        };

        apply(
            &mut reducer,
            &mut session,
            [DriverEvent::RuntimeEventCursorAdvanced(cursor)],
        );

        assert_eq!(session.runtime_event_cursor, Some(cursor));
    }

    #[test]
    fn accepted_turn_is_adopted_once() {
        let mut session = AgentSession::new(Uuid::new_v4(), ProviderKind::Claude);
        let mut reducer = Reducer::default();
        let turn_id = Uuid::new_v4();
        let turn = AgentTurn {
            id: turn_id,
            turn_count: 1,
            status: TurnStatus::Running,
            provider_turn_started: false,
            provider_resume_at: None,
            started_at: unix_time(),
            completed_at: None,
            checkpoint: None,
        };
        let message = Message::new_for_turn(MessageRole::User, "hello", turn_id);

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::TurnAccepted {
                    turn: turn.clone(),
                    messages: vec![message.clone()],
                },
                DriverEvent::TurnAccepted {
                    turn,
                    messages: vec![message],
                },
            ],
        );

        assert_eq!(session.turns.len(), 1);
        assert_eq!(session.messages.len(), 1);
        assert_eq!(session.status, SessionStatus::Connecting);
        assert_eq!(session.active_turn_id(), Some(turn_id));
    }

    #[test]
    fn activity_updates_merge_by_source_id() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::RichActivity(ActivityItem::new(
                    Some("call-1".into()),
                    ActivityKind::Command,
                    "Run tests",
                    None,
                    false,
                )),
                DriverEvent::RichActivity(
                    ActivityItem::new(
                        Some("call-1".into()),
                        ActivityKind::Command,
                        "Run tests",
                        None,
                        true,
                    )
                    .with_output(Some("ok".into())),
                ),
            ],
        );

        let activities = session
            .transcript_blocks
            .iter()
            .flat_map(|block| &block.activities)
            .collect::<Vec<_>>();
        assert_eq!(activities.len(), 1);
        assert!(activities[0].complete);
        assert_eq!(activities[0].output.as_deref(), Some("ok"));
    }

    #[test]
    fn replaced_file_changes_report_the_stale_activity() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();
        let change = |diff: &str| crate::model::ActivityFileChange {
            path: "main.rs".into(),
            additions: Some(1),
            deletions: Some(1),
            status: None,
            diff: Some(diff.into()),
        };
        let mut first = ActivityItem::new(
            Some("edit-1".into()),
            ActivityKind::FileChange,
            "Edit main.rs",
            None,
            false,
        );
        first.file_changes = vec![change("@@\n-a\n+b\n")];
        let activity_id = first.id;
        let mut second = ActivityItem::new(
            Some("edit-1".into()),
            ActivityKind::FileChange,
            "Edit main.rs",
            None,
            true,
        );
        second.file_changes = vec![change("@@\n-b\n+c\n")];

        reducer.apply(
            &mut session,
            DriverEvent::RichActivity(first),
            ReduceContext::default(),
        );
        let reduction = reducer.apply(
            &mut session,
            DriverEvent::RichActivity(second),
            ReduceContext::default(),
        );

        assert_eq!(reduction.replaced_activity_diff, Some(activity_id));
    }

    #[test]
    fn interactions_toggle_waiting_and_working() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [DriverEvent::Permission {
                request_id: "perm-1".into(),
                title: "Run command?".into(),
                detail: "cargo test".into(),
                options: Vec::new(),
            }],
        );
        assert_eq!(session.status, SessionStatus::Waiting);

        apply(
            &mut reducer,
            &mut session,
            [DriverEvent::InteractionResolved {
                request_id: "unknown".into(),
            }],
        );
        assert_eq!(session.status, SessionStatus::Waiting);

        apply(
            &mut reducer,
            &mut session,
            [DriverEvent::InteractionResolved {
                request_id: "perm-1".into(),
            }],
        );
        assert_eq!(session.status, SessionStatus::Working);
    }

    #[test]
    fn failed_turn_without_output_gains_a_fallback_message() {
        let (mut session, turn_id) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::TurnStarted,
                DriverEvent::TurnFinished {
                    success: false,
                    summary: Some("provider rejected the request".into()),
                },
            ],
        );

        assert_eq!(session.status, SessionStatus::Failed);
        assert_eq!(session.turns.last().unwrap().status, TurnStatus::Failed);
        let assistant = session
            .messages
            .iter()
            .find(|message| message.role == MessageRole::Assistant)
            .unwrap();
        assert_eq!(assistant.content, "provider rejected the request");
        assert_eq!(assistant.turn_id, Some(turn_id));
    }

    #[test]
    fn turn_finished_without_a_running_turn_is_ignored() {
        let mut session = AgentSession::new(Uuid::new_v4(), ProviderKind::Claude);
        let mut reducer = Reducer::default();

        let reduction = reducer.apply(
            &mut session,
            DriverEvent::TurnFinished {
                success: true,
                summary: None,
            },
            ReduceContext::default(),
        );

        assert!(!reduction.applied);
        assert!(reduction.finished_turn.is_none());
        assert!(session.messages.is_empty());
        assert_eq!(session.status, SessionStatus::Idle);
    }

    #[test]
    fn process_exit_settles_the_running_turn_as_failed() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(&mut reducer, &mut session, [DriverEvent::TurnStarted]);
        let reduction = reducer.apply(
            &mut session,
            DriverEvent::ProcessExited,
            ReduceContext {
                process_exit_error: Some("connection lost".into()),
                ..ReduceContext::default()
            },
        );

        assert_eq!(session.status, SessionStatus::Failed);
        let finished = reduction.finished_turn.unwrap();
        assert_eq!(finished.status, TurnStatus::Failed);
        assert_eq!(session.turns.last().unwrap().status, TurnStatus::Failed);
        let assistant = session
            .messages
            .iter()
            .find(|message| message.role == MessageRole::Assistant)
            .unwrap();
        assert_eq!(assistant.content, "connection lost");
    }

    #[test]
    fn steer_accepted_joins_the_running_turn() {
        let (mut session, turn_id) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::TurnStarted,
                DriverEvent::SteerAccepted {
                    message: "also update the docs".into(),
                },
            ],
        );

        let steer = session.messages.last().unwrap();
        assert_eq!(steer.role, MessageRole::User);
        assert_eq!(steer.content, "also update the docs");
        assert_eq!(steer.turn_id, Some(turn_id));
        assert_eq!(session.turns.len(), 1, "steering opens no turn boundary");
    }

    #[test]
    fn usage_fields_merge_as_they_arrive() {
        let (mut session, _) = session_with_running_turn();
        let mut reducer = Reducer::default();

        apply(
            &mut reducer,
            &mut session,
            [
                DriverEvent::UsageUpdated {
                    context_tokens: Some(1_200),
                    context_window: None,
                },
                DriverEvent::UsageUpdated {
                    context_tokens: None,
                    context_window: Some(200_000),
                },
            ],
        );

        let usage = session.context_usage.unwrap();
        assert_eq!(usage.tokens, 1_200);
        assert_eq!(usage.window, Some(200_000));
    }
}

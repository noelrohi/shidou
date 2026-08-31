use super::*;

use crate::reducer::{ReduceContext, Reduction, SteerPresentation};

// The projection fold itself lives in the shared canonical Reducer; these
// re-exports keep the app-local seam names for the rest of the module tree.
pub(super) use crate::reducer::{compact_driver_error, session_accepts_turn_output};

impl Shidou {
    pub(super) fn finish_streaming_assistant(&mut self, session_id: Uuid) {
        if let Some(session) = self.state.session_mut(session_id) {
            crate::reducer::finish_streaming_assistant(session);
        }
    }

    pub(super) fn complete_turn_blocks(&mut self, session_id: Uuid) {
        if let Some(session) = self.state.session_mut(session_id) {
            crate::reducer::complete_turn_blocks(session);
        }
    }

    pub(super) fn turn_has_assistant_message(&self, session_id: Uuid) -> bool {
        self.state
            .sessions
            .iter()
            .find(|session| session.id == session_id)
            .is_some_and(crate::reducer::active_turn_has_assistant_message)
    }

    pub(super) fn accepts_turn_output(&mut self, session_id: Uuid) -> bool {
        // The turn begins at submission accept, before its prompt has reached
        // any provider. While preparation is still running, a reused runtime
        // could only be draining leftovers of a settled turn — output landing
        // in the new turn then would attribute stale text to it.
        if self.submission_preparations.contains(&session_id) {
            return false;
        }
        self.state
            .session_mut(session_id)
            .is_some_and(session_accepts_turn_output)
    }

    /// Fold `event` into the session projection through the shared Reducer.
    /// The submission-preparation gate travels in the context so the reducer
    /// applies the same turn-output suppression `accepts_turn_output` does.
    fn reduce_with(
        &mut self,
        session_id: Uuid,
        runtime: &mut SessionRuntime,
        event: DriverEvent,
        mut ctx: ReduceContext,
    ) -> Reduction {
        ctx.suppress_turn_output = self.submission_preparations.contains(&session_id);
        let Some(session) = self.state.session_mut(session_id) else {
            return Reduction::default();
        };
        runtime.reducer.apply(session, event, ctx)
    }

    fn reduce(
        &mut self,
        session_id: Uuid,
        runtime: &mut SessionRuntime,
        event: DriverEvent,
    ) -> Reduction {
        self.reduce_with(session_id, runtime, event, ReduceContext::default())
    }

    /// Returns whether the runtime should remain attached after this event.
    ///
    /// The shared Reducer owns every projection mutation; this handler layers
    /// the desktop-only side effects around it — pending-interaction UI,
    /// notifications, analytics, caches, checkpoints, and queue drains.
    ///
    /// `allow_queue_drain` is false when the caller is flushing buffered
    /// events for a turn the user just stopped: a settling event must not
    /// start queued follow-ups then, because the user asked to stop, not to
    /// continue.
    pub(super) fn handle_driver_event(
        &mut self,
        session_id: Uuid,
        runtime: &mut SessionRuntime,
        event: DriverEvent,
        allow_queue_drain: bool,
        cx: &mut Context<Self>,
    ) -> bool {
        runtime.last_active_at = Instant::now();
        match event {
            DriverEvent::RuntimeEventCursorAdvanced(_)
            | DriverEvent::AgentPresetSelected(_)
            | DriverEvent::AutoTitleUpdated(_)
            | DriverEvent::TurnAccepted { .. } => {
                self.reduce(session_id, runtime, event);
            }
            DriverEvent::Connected { .. } => {
                runtime.last_driver_error = None;
                runtime.last_background_refresh_at = Instant::now();
                runtime.driver.refresh_background_work();
                self.reduce(session_id, runtime, event);
            }
            DriverEvent::AvailableCommands(_) => {
                if self.reduce(session_id, runtime, event).commands_changed {
                    // The drain has no `Context`; the frame loop rebuilds the
                    // drawn index when it sees this.
                    self.composer_sources_stale = true;
                }
            }
            DriverEvent::TurnStarted => {
                runtime.last_driver_error = None;
                self.reduce(session_id, runtime, event);
            }
            DriverEvent::TextDelta(_) => {
                if self.reduce(session_id, runtime, event).applied {
                    self.state.mark_session_dirty(session_id);
                }
            }
            DriverEvent::ReasoningDelta(_) => {
                self.reduce(session_id, runtime, event);
            }
            DriverEvent::Activity {
                id,
                kind,
                title,
                detail,
                complete,
            } => {
                // Built here rather than inside the reducer so the observed
                // item and the stored activity share one identity.
                let item = ActivityItem::new(id, kind, title, detail, complete);
                self.handle_activity_event(session_id, runtime, item, cx);
            }
            DriverEvent::RichActivity(item) => {
                self.handle_activity_event(session_id, runtime, item, cx);
            }
            DriverEvent::BackgroundWork(event) => {
                // Background work is session state, not turn output. It must
                // survive a settled or rewound turn and therefore bypasses
                // the reducer's turn-output gate deliberately.
                self.handle_background_work_event(session_id, event);
            }
            DriverEvent::Permission {
                request_id,
                title,
                detail,
                options,
            } => {
                let pending = PendingPermission {
                    request_id: request_id.clone(),
                    title: title.clone(),
                    detail: detail.clone(),
                    options: options.clone(),
                };
                let event = DriverEvent::Permission {
                    request_id,
                    title,
                    detail,
                    options,
                };
                if self.reduce(session_id, runtime, event).applied {
                    runtime.pending_permission = Some(pending);
                }
            }
            DriverEvent::UserInputRequested {
                request_id,
                questions,
            } => {
                let pending = (request_id.clone(), questions.clone());
                let event = DriverEvent::UserInputRequested {
                    request_id,
                    questions,
                };
                if self.reduce(session_id, runtime, event).applied {
                    runtime.pending_user_input = Some(PendingUserInput::new(pending.0, pending.1));
                    if self.state.selected_session == Some(session_id) {
                        self.user_input_answer
                            .update(cx, |input, cx| input.clear(cx));
                    }
                }
            }
            DriverEvent::InteractionResolved { request_id } => {
                let user_input_matches = runtime
                    .pending_user_input
                    .as_ref()
                    .is_some_and(|pending| pending.request_id == request_id);
                if runtime
                    .pending_permission
                    .as_ref()
                    .is_some_and(|pending| pending.request_id == request_id)
                {
                    runtime.pending_permission = None;
                }
                if user_input_matches {
                    runtime.pending_user_input = None;
                    if self.state.selected_session == Some(session_id) {
                        self.user_input_answer
                            .update(cx, |input, cx| input.clear(cx));
                    }
                }
                self.reduce(
                    session_id,
                    runtime,
                    DriverEvent::InteractionResolved { request_id },
                );
            }
            DriverEvent::ComputerUseUpdated(state) => {
                if self.accepts_turn_output(session_id) {
                    Self::upsert_computer_use_preview(runtime, state);
                }
            }
            DriverEvent::SteerAccepted { message } => {
                let submission = runtime
                    .pending_steers
                    .iter()
                    .position(|submission| submission.prompt == message)
                    .and_then(|index| runtime.pending_steers.remove(index))
                    // Providers normally echo the exact transport text, but a
                    // normalized echo still acknowledges the oldest pending
                    // steer. Preserve its attachment presentation metadata.
                    .or_else(|| runtime.pending_steers.pop_front())
                    .unwrap_or_else(|| ComposerSubmission::plain(message.clone()));
                self.reduce_with(
                    session_id,
                    runtime,
                    DriverEvent::SteerAccepted { message },
                    ReduceContext {
                        steer_presentation: Some(SteerPresentation {
                            display_content: submission.display_content,
                            attachments: submission.attachments,
                        }),
                        ..ReduceContext::default()
                    },
                );
            }
            DriverEvent::SteerRejected { message, reason } => {
                let submission = runtime
                    .pending_steers
                    .iter()
                    .position(|submission| submission.prompt == message)
                    .and_then(|index| runtime.pending_steers.remove(index))
                    .or_else(|| runtime.pending_steers.pop_front())
                    .unwrap_or_else(|| ComposerSubmission::plain(message));
                let (busy, settled_cleanly) = self
                    .state
                    .sessions
                    .iter()
                    .find(|session| session.id == session_id)
                    .map(|session| {
                        let settled_cleanly = session
                            .turns
                            .last()
                            .is_some_and(|turn| turn.status == TurnStatus::Completed);
                        (session.is_busy(), settled_cleanly)
                    })
                    .unwrap_or((false, false));
                if busy {
                    self.enqueue_follow_up_submission(session_id, submission, cx);
                    if self.state.selected_session == Some(session_id) {
                        self.show_toast(tr!(
                            "session.steer_rejected",
                            error = compact_driver_error(&reason)
                        ));
                    }
                } else if settled_cleanly {
                    // The turn settled before the steer arrived; run the
                    // message as a fresh turn instead of losing it. Submission
                    // is deferred through the queue-drain pass because this
                    // session's runtime is detached from the map while its
                    // events are handled — an inline submit would spawn a
                    // second driver process only to have it clobbered when the
                    // drain re-inserts the detached runtime.
                    if let Some(session) = self.state.session_mut(session_id) {
                        session
                            .queued_messages
                            .insert(0, submission.into_queued_message());
                    }
                    if allow_queue_drain {
                        self.pending_queue_drains.push(session_id);
                    }
                } else {
                    // The user stopped the turn (or the provider died) before
                    // the steer landed. Keep the message visible and
                    // user-controlled instead of auto-running it.
                    self.enqueue_follow_up_submission(session_id, submission, cx);
                }
            }
            DriverEvent::PlanUsageUpdated(usage) => {
                if let Some(provider) = self
                    .state
                    .sessions
                    .iter()
                    .find(|session| session.id == session_id)
                    .map(|session| session.provider)
                {
                    self.plan_usage.insert(provider, usage);
                }
            }
            DriverEvent::UsageUpdated { .. } => {
                if self.reduce(session_id, runtime, event).applied {
                    self.state.mark_session_dirty(session_id);
                }
            }
            DriverEvent::TurnFinished { success, summary } => {
                self.settle_foreground_work(
                    session_id,
                    if success {
                        BackgroundWorkStatus::Completed
                    } else {
                        BackgroundWorkStatus::Failed
                    },
                );
                let previous_kinds = self.snapshot_selected_transcript_rows(session_id);
                runtime.last_driver_error = None;
                // A settled turn moved the account's rate-limit needles; ask
                // that provider's plan meter to refresh once its backoff
                // allows.
                if let Some(provider) = self
                    .state
                    .sessions
                    .iter()
                    .find(|session| session.id == session_id)
                    .map(|session| session.provider)
                    .filter(|provider| usage_meter::PLAN_USAGE_PROVIDERS.contains(provider))
                {
                    self.plan_usage_stale.insert(provider);
                }
                if self
                    .state
                    .sessions
                    .iter()
                    .find(|session| session.id == session_id)
                    .and_then(AgentSession::active_turn_id)
                    .is_none()
                {
                    return true;
                }
                let task_notification = cx.active_window().is_none().then(|| {
                    self.state
                        .sessions
                        .iter()
                        .find(|session| session.id == session_id)
                        .map(|session| {
                            let title = if session.display_title() == AgentSession::DEFAULT_TITLE {
                                tr!("session.new_task")
                            } else {
                                session.display_title().to_owned()
                            };
                            let body = if success {
                                tr!("session.turn_completed")
                            } else {
                                tr!("session.stopped")
                            };
                            (title, body)
                        })
                });
                // The analytics event reads the still-running turn, so it is
                // captured before the reducer settles it and emitted only if
                // the settlement really happened — the same
                // capture-then-confirm order `finish_active_turn_with_analytics`
                // uses on the other settlement paths.
                let analytics_event = self.active_turn_finished_event(
                    session_id,
                    if success {
                        crate::analytics::TurnOutcome::Completed
                    } else {
                        crate::analytics::TurnOutcome::Failed
                    },
                );
                let reduction = self.reduce(
                    session_id,
                    runtime,
                    DriverEvent::TurnFinished { success, summary },
                );
                if reduction.finished_turn.is_some()
                    && let Some(event) = analytics_event
                {
                    self.analytics.track(event);
                }
                runtime.pending_permission = None;
                runtime.pending_user_input = None;
                runtime.pending_computer_approval = None;
                runtime.driver.cancel_computer_use();
                // The agent may have edited files or switched branches, so the
                // cached view of the workspace is no longer trustworthy. This
                // handler has no `Context`, so the drain loop acts on the flag.
                if self.state.selected_session == Some(session_id) {
                    self.workspace_queries_stale = true;
                }
                runtime.computer_use_previews.clear();
                runtime.driver.refresh_background_work();
                self.capture_latest_turn_checkpoint_for(session_id);
                if allow_queue_drain && success {
                    // Start the next queued follow-up once the runtime has
                    // been re-inserted so the same process is reused.
                    self.pending_queue_drains.push(session_id);
                }
                if let Some(previous_kinds) = previous_kinds.as_deref() {
                    self.splice_active_transcript_rows_after_visibility_change(previous_kinds);
                }
                if let Some(Some((title, body))) = task_notification {
                    crate::platform::show_task_notification(
                        &task_notification_tag(session_id),
                        &title,
                        &body,
                        cx,
                    );
                }
            }
            DriverEvent::Error(error) => {
                let compact = compact_driver_error(&error);
                runtime.last_driver_error = Some(compact.clone());
                if self.state.selected_session == Some(session_id) {
                    self.show_toast(compact);
                }
                self.reduce(session_id, runtime, DriverEvent::Error(error));
            }
            DriverEvent::ProcessExited => {
                self.mark_background_work_lost(session_id);
                let previous_kinds = self.snapshot_selected_transcript_rows(session_id);
                runtime.pending_permission = None;
                runtime.pending_user_input = None;
                runtime.pending_computer_approval = None;
                runtime.driver.cancel_computer_use();
                runtime.computer_use_previews.clear();
                let analytics_event = self.active_turn_finished_event(
                    session_id,
                    crate::analytics::TurnOutcome::ProcessExited,
                );
                let process_exit_error = runtime.last_driver_error.take();
                let reduction = self.reduce_with(
                    session_id,
                    runtime,
                    DriverEvent::ProcessExited,
                    ReduceContext {
                        process_exit_error,
                        ..ReduceContext::default()
                    },
                );
                if reduction.finished_turn.is_some() {
                    if let Some(event) = analytics_event {
                        self.analytics.track(event);
                    }
                    self.capture_latest_turn_checkpoint_for(session_id);
                }
                if let Some(previous_kinds) = previous_kinds.as_deref() {
                    self.splice_active_transcript_rows_after_visibility_change(previous_kinds);
                }
                return false;
            }
        }
        true
    }

    fn handle_activity_event(
        &mut self,
        session_id: Uuid,
        runtime: &mut SessionRuntime,
        item: ActivityItem,
        cx: &mut Context<Self>,
    ) {
        let refresh_branch = should_refresh_branch_after_activity(item.kind, item.complete)
            && self.state.selected_session == Some(session_id);
        let observed = item.clone();
        let reduction = self.reduce(session_id, runtime, DriverEvent::RichActivity(item));
        if !reduction.applied {
            return;
        }
        self.observe_foreground_command_activity(session_id, &observed);
        if let Some(activity_id) = reduction.replaced_activity_diff {
            // The rows this activity's diff was built from are gone;
            // an expanded card rebuilds from the new ones.
            self.activity_diffs.borrow_mut().remove(&activity_id);
        }
        if refresh_branch {
            self.refresh_selected_branch_snapshot(cx);
        }
    }

    fn upsert_computer_use_preview(runtime: &mut SessionRuntime, state: ComputerUseState) {
        if !state.visible {
            return;
        }
        let Some(window_id) = state.target.as_ref().map(|target| target.window_id) else {
            return;
        };
        let mut preview = ComputerUsePreview {
            target: state.target,
            phase: state.phase,
            visible: state.visible,
            screenshot: state.image_url.as_deref().and_then(|image_url| {
                crate::computer_use::decode_preview_image_url(image_url).ok()
            }),
        };
        if let Some(index) = runtime.computer_use_previews.iter().position(|preview| {
            preview
                .target
                .as_ref()
                .is_some_and(|target| target.window_id == window_id)
        }) {
            let previous = runtime.computer_use_previews.remove(index);
            if preview.screenshot.is_none() {
                preview.screenshot = previous.screenshot;
            }
        }
        runtime.computer_use_previews.push(preview);
    }
}

/// A completed edit or shell command is the earliest provider-neutral point at
/// which its filesystem effects are stable enough to re-read. The actual Git
/// work remains behind the branch cache's background fetch.
pub(super) fn should_refresh_branch_after_activity(
    kind: crate::model::ActivityKind,
    complete: bool,
) -> bool {
    complete
        && matches!(
            kind,
            crate::model::ActivityKind::Command | crate::model::ActivityKind::FileChange
        )
}

pub(super) fn stream_delta_kind(event: &DriverEvent) -> Option<StreamDeltaKind> {
    match event {
        DriverEvent::TextDelta(_) => Some(StreamDeltaKind::Text),
        DriverEvent::ReasoningDelta(_) => Some(StreamDeltaKind::Reasoning),
        _ => None,
    }
}

pub(super) fn stream_delta_text(event: &DriverEvent, kind: StreamDeltaKind) -> Option<&str> {
    match (kind, event) {
        (StreamDeltaKind::Text, DriverEvent::TextDelta(text))
        | (StreamDeltaKind::Reasoning, DriverEvent::ReasoningDelta(text)) => Some(text),
        _ => None,
    }
}

/// Coalesce every adjacent delta of one kind while retaining provider order.
/// Runtime cursors are acknowledgements rather than visible boundaries, so the
/// newest cursor follows the combined delta. The full text enters layout in
/// this pass; Markdown's paint-only veil provides the progressive dissolve.
pub(super) fn pop_stream_batch(
    events: &mut VecDeque<DriverEvent>,
    kind: StreamDeltaKind,
) -> Option<DriverEvent> {
    let mut chunk = String::new();
    let mut latest_cursor = None;
    loop {
        match events.front() {
            Some(DriverEvent::RuntimeEventCursorAdvanced(_)) => {
                latest_cursor = events.pop_front();
            }
            Some(event) if stream_delta_text(event, kind).is_some() => {
                let event = events.pop_front()?;
                match (kind, event) {
                    (StreamDeltaKind::Text, DriverEvent::TextDelta(text))
                    | (StreamDeltaKind::Reasoning, DriverEvent::ReasoningDelta(text)) => {
                        chunk.push_str(&text);
                    }
                    _ => unreachable!("the stream kind was checked before removing the event"),
                }
            }
            _ => break,
        }
    }
    if let Some(cursor) = latest_cursor {
        events.push_front(cursor);
    }
    match kind {
        StreamDeltaKind::Text => Some(DriverEvent::TextDelta(chunk)),
        StreamDeltaKind::Reasoning => Some(DriverEvent::ReasoningDelta(chunk)),
    }
}

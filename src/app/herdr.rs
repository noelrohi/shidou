use super::*;

const HERDR_ACTIVE_POLL_INTERVAL: Duration = Duration::from_millis(1_500);
const HERDR_IDLE_POLL_INTERVAL: Duration = Duration::from_secs(5);

impl Shidou {
    /// Keep the sidebar's Herdr snapshot current. The loop owns all daemon I/O;
    /// render and row builders only read the last in-memory result.
    pub(super) fn start_herdr_polling(&mut self, cx: &mut Context<Self>) {
        if self.herdr_polling {
            return;
        }
        self.herdr_polling = true;
        self.refresh_herdr_state(cx);
    }

    pub(super) fn stop_herdr_polling(&mut self) {
        self.herdr_polling = false;
        self.herdr_loading = false;
        self.herdr_poll_generation = self.herdr_poll_generation.wrapping_add(1);
        self.herdr_output_generation = self.herdr_output_generation.wrapping_add(1);
    }

    pub(super) fn refresh_herdr_state(&mut self, cx: &mut Context<Self>) {
        if self.herdr_loading {
            return;
        }
        self.herdr_loading = true;
        self.herdr_error = None;
        self.herdr_poll_generation = self.herdr_poll_generation.wrapping_add(1);
        let generation = self.herdr_poll_generation;
        let client = self.daemon.client();
        cx.spawn(async move |this, cx| {
            let response = cx
                .background_executor()
                .spawn(async move {
                    client.request(
                        Uuid::nil(),
                        Uuid::nil(),
                        shidou_client::Command::LoadHerdrState,
                    )
                })
                .await;
            let poll_interval = this
                .update(cx, |this, cx| {
                    if this.herdr_poll_generation != generation {
                        return None;
                    }
                    this.herdr_loading = false;
                    match response {
                        Ok(shidou_client::ResponsePayload::HerdrState { state }) => {
                            let active_terminal =
                                this.main_destination.herdr_terminal_id().map(str::to_owned);
                            let mut active_exists =
                                active_terminal.as_ref().is_some_and(|selected| {
                                    state
                                        .agents
                                        .iter()
                                        .any(|agent| &agent.terminal_id == selected)
                                });
                            if active_terminal.is_some() && !active_exists {
                                this.herdr_output = None;
                                if this.state.herdr_enabled {
                                    if let Some(agent) = state.agents.first() {
                                        this.main_destination = MainDestination::HerdrTerminal(
                                            agent.terminal_id.clone(),
                                        );
                                        active_exists = true;
                                    } else {
                                        this.main_destination =
                                            MainDestination::HerdrTerminal(String::new());
                                    }
                                } else {
                                    this.main_destination = MainDestination::Task;
                                }
                            }
                            this.herdr_workspace_focuses
                                .borrow_mut()
                                .retain(|workspace_id, _| {
                                    workspace_id.is_empty()
                                        || state
                                            .workspaces
                                            .iter()
                                            .any(|workspace| &workspace.id == workspace_id)
                                });
                            this.herdr_agent_focuses
                                .borrow_mut()
                                .retain(|terminal_id, _| {
                                    state
                                        .agents
                                        .iter()
                                        .any(|agent| &agent.terminal_id == terminal_id)
                                });
                            this.herdr_state = state;
                            this.herdr_error = None;
                            this.sidebar_rows_fingerprint.set(None);
                            if active_exists {
                                this.refresh_selected_herdr_output(cx);
                            }
                        }
                        Ok(_) => {
                            this.herdr_error =
                                Some("The daemon returned an invalid Herdr response".into())
                        }
                        Err(error) => this.herdr_error = Some(error.to_string()),
                    }
                    cx.notify();
                    this.herdr_polling.then(|| {
                        if this.main_destination.herdr_terminal_id().is_some() {
                            HERDR_ACTIVE_POLL_INTERVAL
                        } else {
                            HERDR_IDLE_POLL_INTERVAL
                        }
                    })
                })
                .ok()
                .flatten();
            let Some(interval) = poll_interval else {
                return;
            };
            cx.background_executor().timer(interval).await;
            let _ = this.update(cx, |this, cx| {
                if this.herdr_poll_generation == generation {
                    this.refresh_herdr_state(cx);
                }
            });
        })
        .detach();
    }

    pub(super) fn refresh_selected_herdr_output(&mut self, cx: &mut Context<Self>) {
        self.herdr_output_generation = self.herdr_output_generation.wrapping_add(1);
        let generation = self.herdr_output_generation;
        let Some(agent) = self.selected_herdr_agent().cloned() else {
            self.herdr_output = None;
            return;
        };
        let client = self.daemon.client();
        let terminal_id = agent.terminal_id;
        let request_terminal_id = terminal_id.clone();
        cx.spawn(async move |this, cx| {
            let response = cx
                .background_executor()
                .spawn(async move {
                    client.request(
                        Uuid::nil(),
                        Uuid::nil(),
                        shidou_client::Command::ReadHerdrAgent {
                            terminal_id: request_terminal_id,
                            lines: 240,
                        },
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.herdr_output_generation != generation {
                    return;
                }
                match response {
                    Ok(shidou_client::ResponsePayload::HerdrAgentOutput { output })
                        if this.main_destination.herdr_terminal_id() == Some(&terminal_id) =>
                    {
                        this.herdr_output = Some(output);
                        this.herdr_error = None;
                    }
                    Ok(shidou_client::ResponsePayload::HerdrAgentOutput { .. }) => {}
                    Ok(_) => {
                        this.herdr_error = Some("The daemon returned invalid Herdr output".into())
                    }
                    Err(error) => this.herdr_error = Some(error.to_string()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn selected_herdr_agent(&self) -> Option<&shidou_client::HerdrAgent> {
        let selected = self.main_destination.herdr_terminal_id()?;
        self.herdr_state
            .agents
            .iter()
            .find(|agent| agent.terminal_id == selected)
    }

    pub(super) fn herdr_agent_title(agent: &shidou_client::HerdrAgent) -> &str {
        agent
            .title
            .as_deref()
            .or(agent.name.as_deref())
            .unwrap_or(&agent.agent)
    }

    pub(super) fn select_herdr_agent(&mut self, terminal_id: String, cx: &mut Context<Self>) {
        let exists = self
            .herdr_state
            .agents
            .iter()
            .any(|agent| agent.terminal_id == terminal_id);
        if !exists {
            return;
        }
        let destination_changed =
            self.main_destination.herdr_terminal_id() != Some(terminal_id.as_str());
        if destination_changed && self.main_destination == MainDestination::Task {
            self.capture_and_save_current_composer_draft(cx);
            self.store_selected_right_panel_state();
        }
        self.settings_page = None;
        self.main_destination = MainDestination::HerdrTerminal(terminal_id);
        self.pending_session_activation = None;
        if destination_changed {
            self.herdr_output = None;
            self.refresh_selected_herdr_output(cx);
        }
        cx.notify();
    }

    pub(super) fn send_herdr_prompt(&mut self, cx: &mut Context<Self>) {
        let prompt = self
            .herdr_prompt_input
            .read(cx)
            .content(cx)
            .trim()
            .to_owned();
        if prompt.is_empty() {
            return;
        }
        self.herdr_prompt_input
            .update(cx, |input, cx| input.clear(cx));
        self.submit_herdr_prompt(prompt, cx);
    }

    pub(super) fn submit_herdr_prompt(&mut self, prompt: String, cx: &mut Context<Self>) {
        let Some(agent) = self.selected_herdr_agent().cloned() else {
            return;
        };
        let client = self.daemon.client();
        let submitted = prompt.clone();
        cx.spawn(async move |this, cx| {
            let response = cx
                .background_executor()
                .spawn(async move {
                    client.request(
                        Uuid::nil(),
                        Uuid::nil(),
                        shidou_client::Command::PromptHerdrAgent {
                            terminal_id: agent.terminal_id,
                            prompt: submitted,
                        },
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Err(error) = response {
                    this.herdr_error = Some(error.to_string());
                    this.herdr_prompt_input
                        .update(cx, |input, cx| input.set_content(prompt, cx));
                }
                this.refresh_selected_herdr_output(cx);
                cx.notify();
            });
        })
        .detach();
    }

    fn send_herdr_keys(&mut self, keys: Vec<String>, cx: &mut Context<Self>) {
        let Some(agent) = self.selected_herdr_agent().cloned() else {
            return;
        };
        let client = self.daemon.client();
        cx.spawn(async move |this, cx| {
            let response = cx
                .background_executor()
                .spawn(async move {
                    client.request(
                        Uuid::nil(),
                        Uuid::nil(),
                        shidou_client::Command::SendHerdrAgentKeys {
                            terminal_id: agent.terminal_id,
                            keys,
                        },
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Err(error) = response {
                    this.herdr_error = Some(error.to_string());
                }
                this.refresh_selected_herdr_output(cx);
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn herdr_prompt_focus(&self, cx: &App) -> FocusHandle {
        self.herdr_prompt_input.read(cx).focus()
    }

    pub(super) fn render_herdr_conversation(&self, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::current(cx);
        let selected = self.selected_herdr_agent();
        let output = self.herdr_output.as_ref().map(|output| output.text.clone());

        let refresh = div()
            .id("herdr-refresh")
            .track_focus(&self.herdr_refresh_focus)
            .tab_index(0)
            .tab_group()
            .tab_stop(true)
            .focus_visible(|style| style.border_1().border_color(theme.accent))
            .px(px(10.0))
            .py(px(6.0))
            .rounded(px(7.0))
            .cursor_default()
            .text_size(sp(12.0))
            .bg(theme.overlay)
            .hover(|style| style.bg(theme.overlay_strong))
            .child(if self.herdr_loading {
                "Refreshing"
            } else {
                "Refresh"
            })
            .on_click(cx.listener(|this, _, _, cx| this.refresh_herdr_state(cx)))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                    this.refresh_herdr_state(cx);
                    cx.stop_propagation();
                }
            }));

        let body = if let Some(agent) = selected {
            div()
                .flex_1()
                .min_h_0()
                .w_full()
                .flex()
                .flex_col()
                .child(
                    div()
                        .w_full()
                        .max_w(px(CONTENT_MAX_WIDTH))
                        .mx_auto()
                        .px(px(20.0))
                        .pt(px(16.0))
                        .flex()
                        .items_center()
                        .gap(px(7.0))
                        .text_size(sp(12.0))
                        .text_color(theme.text_tertiary)
                        .child(icon(
                            herdr_status_icon(agent.status),
                            13.0,
                            herdr_status_color(agent.status, &theme),
                        ))
                        .child(herdr_status_label(agent.status))
                        .child("·")
                        .child(agent.agent.clone())
                        .child(div().flex_1())
                        .child(refresh),
                )
                .when_some(self.herdr_error.clone(), |element, error| {
                    element.child(
                        div()
                            .w_full()
                            .max_w(px(CONTENT_MAX_WIDTH))
                            .mx_auto()
                            .mt(px(10.0))
                            .px(px(20.0))
                            .child(
                                div()
                                    .p(px(10.0))
                                    .rounded(px(8.0))
                                    .bg(theme.danger_soft)
                                    .text_size(sp(12.0))
                                    .text_color(theme.danger)
                                    .child(error),
                            ),
                    )
                })
                .child(
                    div()
                        .id("herdr-conversation-output")
                        .flex_1()
                        .min_h_0()
                        .overflow_y_scroll()
                        .child(
                            div()
                                .w_full()
                                .max_w(px(CONTENT_MAX_WIDTH))
                                .mx_auto()
                                .px(px(20.0))
                                .py(px(24.0))
                                .font_family(".SystemUIFontMonospaced")
                                .text_size(sp(12.5))
                                .line_height(sp(19.0))
                                .text_color(theme.text)
                                .whitespace_normal()
                                .child(
                                    output.unwrap_or_else(|| "Loading terminal output...".into()),
                                ),
                        ),
                )
                .into_any_element()
        } else {
            div()
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(12.0))
                .text_center()
                .child(icon("icons/terminal.svg", 24.0, theme.text_tertiary))
                .child(
                    div()
                        .text_size(sp(14.0))
                        .font_weight(FontWeight::MEDIUM)
                        .child(if self.herdr_state.available {
                            "This Herdr agent is no longer available".to_owned()
                        } else {
                            self.herdr_state
                                .unavailable_reason
                                .clone()
                                .unwrap_or_else(|| "Herdr is not connected".into())
                        }),
                )
                .child(refresh)
                .into_any_element()
        };

        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(body)
            .when(selected.is_some(), |element| {
                element.child(self.render_herdr_composer(cx))
            })
            .into_any_element()
    }

    fn render_herdr_composer(&self, cx: &mut Context<Self>) -> Div {
        let theme = Theme::current(cx);
        let control = |id: &'static str,
                       focus: &FocusHandle,
                       label: &'static str,
                       primary: bool|
         -> Stateful<Div> {
            div()
                .id(id)
                .track_focus(focus)
                .tab_index(0)
                .tab_group()
                .tab_stop(true)
                .focus_visible(|style| style.border_1().border_color(theme.accent))
                .px(px(if primary { 13.0 } else { 9.0 }))
                .h(px(30.0))
                .rounded(px(7.0))
                .flex()
                .items_center()
                .cursor_default()
                .text_size(sp(12.0))
                .bg(if primary { theme.accent } else { theme.overlay })
                .text_color(if primary {
                    theme.on_inverse
                } else {
                    theme.text_secondary
                })
                .hover(|style| style.opacity(0.86))
                .child(label)
        };
        let escape = control("herdr-escape", &self.herdr_escape_focus, "Escape", false)
            .on_click(cx.listener(|this, _, _, cx| this.send_herdr_keys(vec!["esc".into()], cx)))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                    this.send_herdr_keys(vec!["esc".into()], cx);
                    cx.stop_propagation();
                }
            }));
        let interrupt = control(
            "herdr-interrupt",
            &self.herdr_interrupt_focus,
            "Interrupt",
            false,
        )
        .on_click(cx.listener(|this, _, _, cx| this.send_herdr_keys(vec!["ctrl+c".into()], cx)))
        .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                this.send_herdr_keys(vec!["ctrl+c".into()], cx);
                cx.stop_propagation();
            }
        }));
        let send = control("herdr-send", &self.herdr_send_focus, "Send", true)
            .on_click(cx.listener(|this, _, _, cx| this.send_herdr_prompt(cx)))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                    this.send_herdr_prompt(cx);
                    cx.stop_propagation();
                }
            }));

        div()
            .flex_none()
            .w_full()
            .px(px(20.0))
            .pt(px(12.0))
            .pb(px(18.0))
            .child(
                div()
                    .w_full()
                    .max_w(px(CONTENT_MAX_WIDTH))
                    .mx_auto()
                    .py(px(10.0))
                    .rounded(px(13.0))
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.composer)
                    .child(div().pt(px(2.0)).child(self.herdr_prompt_input.clone()))
                    .child(
                        div()
                            .mt(px(8.0))
                            .px(px(10.0))
                            .flex()
                            .items_center()
                            .gap(px(4.0))
                            .child(escape)
                            .child(interrupt)
                            .child(div().flex_1())
                            .child(send),
                    ),
            )
    }
}

pub(super) fn herdr_status_label(status: shidou_client::HerdrAgentStatus) -> &'static str {
    match status {
        shidou_client::HerdrAgentStatus::Working => "Working",
        shidou_client::HerdrAgentStatus::Blocked => "Blocked",
        shidou_client::HerdrAgentStatus::Done => "Done",
        shidou_client::HerdrAgentStatus::Idle => "Idle",
        shidou_client::HerdrAgentStatus::Unknown => "Unknown",
    }
}

pub(super) fn herdr_status_icon(status: shidou_client::HerdrAgentStatus) -> &'static str {
    match status {
        shidou_client::HerdrAgentStatus::Working => "icons/loader-circle.svg",
        shidou_client::HerdrAgentStatus::Blocked => "icons/alert.svg",
        shidou_client::HerdrAgentStatus::Done => "icons/check.svg",
        shidou_client::HerdrAgentStatus::Idle | shidou_client::HerdrAgentStatus::Unknown => {
            "icons/terminal.svg"
        }
    }
}

pub(super) fn herdr_status_color(status: shidou_client::HerdrAgentStatus, theme: &Theme) -> Hsla {
    match status {
        shidou_client::HerdrAgentStatus::Working => theme.gauge,
        shidou_client::HerdrAgentStatus::Blocked => theme.warning,
        shidou_client::HerdrAgentStatus::Done => theme.success,
        shidou_client::HerdrAgentStatus::Idle | shidou_client::HerdrAgentStatus::Unknown => {
            theme.text_tertiary
        }
    }
}

use super::*;

impl Shidou {
    pub(super) fn refresh_herdr_state(&mut self, cx: &mut Context<Self>) {
        if self.herdr_loading {
            return;
        }
        self.herdr_loading = true;
        self.herdr_error = None;
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
            this.update(cx, |this, cx| {
                this.herdr_loading = false;
                match response {
                    Ok(shidou_client::ResponsePayload::HerdrState { state }) => {
                        if this
                            .herdr_selected_terminal
                            .as_ref()
                            .is_none_or(|selected| {
                                !state
                                    .agents
                                    .iter()
                                    .any(|agent| &agent.terminal_id == selected)
                            })
                        {
                            this.herdr_selected_terminal =
                                state.agents.first().map(|agent| agent.terminal_id.clone());
                        }
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
                        this.refresh_selected_herdr_output(cx);
                    }
                    Ok(_) => {
                        this.herdr_error =
                            Some("The daemon returned an invalid Herdr response".into())
                    }
                    Err(error) => this.herdr_error = Some(error.to_string()),
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn refresh_selected_herdr_output(&mut self, cx: &mut Context<Self>) {
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
            let keep_polling = this
                .update(cx, |this, cx| {
                    if this.herdr_output_generation != generation {
                        return false;
                    }
                    match response {
                        Ok(shidou_client::ResponsePayload::HerdrAgentOutput { output })
                            if this.herdr_selected_terminal.as_deref() == Some(&terminal_id) =>
                        {
                            this.herdr_output = Some(output);
                        }
                        Ok(shidou_client::ResponsePayload::HerdrAgentOutput { .. }) => {}
                        Ok(_) => {
                            this.herdr_error =
                                Some("The daemon returned invalid Herdr output".into())
                        }
                        Err(error) => this.herdr_error = Some(error.to_string()),
                    }
                    cx.notify();
                    this.settings_page == Some(SettingsPage::Herdr)
                })
                .unwrap_or(false);
            if keep_polling {
                cx.background_executor()
                    .timer(Duration::from_millis(1_500))
                    .await;
                let _ = this.update(cx, |this, cx| {
                    if this.herdr_output_generation == generation
                        && this.settings_page == Some(SettingsPage::Herdr)
                    {
                        this.refresh_herdr_state(cx);
                    }
                });
            }
        })
        .detach();
    }

    fn selected_herdr_agent(&self) -> Option<&shidou_client::HerdrAgent> {
        let selected = self.herdr_selected_terminal.as_deref()?;
        self.herdr_state
            .agents
            .iter()
            .find(|agent| agent.terminal_id == selected)
    }

    fn select_herdr_agent(&mut self, terminal_id: String, cx: &mut Context<Self>) {
        if self.herdr_selected_terminal.as_deref() == Some(&terminal_id) {
            return;
        }
        self.herdr_selected_terminal = Some(terminal_id);
        self.herdr_output = None;
        self.refresh_selected_herdr_output(cx);
        cx.notify();
    }

    pub(super) fn send_herdr_prompt(&mut self, cx: &mut Context<Self>) {
        let prompt = self.herdr_prompt_input.read(cx).content().trim().to_owned();
        let Some(agent) = self.selected_herdr_agent().cloned() else {
            return;
        };
        if prompt.is_empty() {
            return;
        }
        self.herdr_prompt_input
            .update(cx, |input, cx| input.set_content("", cx));
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
            this.update(cx, |this, cx| {
                if let Err(error) = response {
                    this.herdr_error = Some(error.to_string());
                    this.herdr_prompt_input
                        .update(cx, |input, cx| input.set_content(prompt, cx));
                }
                this.refresh_herdr_state(cx);
                cx.notify();
            })
            .ok();
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
            this.update(cx, |this, cx| {
                if let Err(error) = response {
                    this.herdr_error = Some(error.to_string());
                }
                this.refresh_selected_herdr_output(cx);
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    pub(super) fn render_herdr_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::current(cx);
        let selected = self.selected_herdr_agent().cloned();
        let mut agents = div().flex().flex_col().gap(px(6.0));
        for workspace in &self.herdr_state.workspaces {
            agents = agents.child(
                div()
                    .pt(px(10.0))
                    .text_size(sp(12.0))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.text_secondary)
                    .child(workspace.label.clone()),
            );
            for agent in self
                .herdr_state
                .agents
                .iter()
                .filter(|agent| agent.workspace_id == workspace.id)
            {
                let terminal_id = agent.terminal_id.clone();
                let focus = self
                    .herdr_agent_focuses
                    .borrow_mut()
                    .entry(terminal_id.clone())
                    .or_insert_with(|| cx.focus_handle())
                    .clone();
                let click_terminal_id = terminal_id.clone();
                let key_terminal_id = terminal_id.clone();
                let selected = self.herdr_selected_terminal.as_deref() == Some(&terminal_id);
                let title = agent
                    .title
                    .as_deref()
                    .or(agent.name.as_deref())
                    .unwrap_or(&agent.agent)
                    .to_owned();
                agents = agents.child(
                    div()
                        .id(SharedString::from(format!("herdr-agent-{terminal_id}")))
                        .track_focus(&focus)
                        .tab_index(0)
                        .tab_group()
                        .tab_stop(true)
                        .focus_visible(|style| style.text_color(theme.accent))
                        .px(px(10.0))
                        .py(px(8.0))
                        .rounded(px(8.0))
                        .cursor_default()
                        .when(selected, |element| {
                            element.bg(theme.sidebar_item_background)
                        })
                        .hover(|element| element.bg(theme.sidebar_item_background))
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(8.0))
                                .child(
                                    div()
                                        .size(px(7.0))
                                        .rounded(px(4.0))
                                        .bg(herdr_status_color(agent.status, &theme)),
                                )
                                .child(div().flex_1().min_w_0().text_size(sp(13.0)).child(title))
                                .child(
                                    div()
                                        .text_size(sp(11.0))
                                        .text_color(theme.text_tertiary)
                                        .child(format!("{:?}", agent.status).to_lowercase()),
                                ),
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.select_herdr_agent(click_terminal_id.clone(), cx);
                        }))
                        .on_key_down(cx.listener(move |this, event: &KeyDownEvent, _, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.select_herdr_agent(key_terminal_id.clone(), cx);
                                cx.stop_propagation();
                            }
                        })),
                );
            }
        }

        let output = self
            .herdr_output
            .as_ref()
            .map(|output| output.text.clone())
            .unwrap_or_else(|| {
                if selected.is_some() {
                    "Loading terminal output…".into()
                } else {
                    "Select an agent.".into()
                }
            });

        div()
            .pt(px(18.0))
            .flex()
            .flex_col()
            .gap(px(14.0))
            .child(
                div()
                    .flex()
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(sp(13.0))
                            .text_color(theme.text_secondary)
                            .child(if self.herdr_state.available {
                                format!(
                                    "Herdr {} · {} agents",
                                    self.herdr_state.version.as_deref().unwrap_or(""),
                                    self.herdr_state.agents.len()
                                )
                            } else {
                                self.herdr_state
                                    .unavailable_reason
                                    .clone()
                                    .unwrap_or_else(|| "Herdr is not connected".into())
                            }),
                    )
                    .child(
                        div()
                            .id("herdr-refresh")
                            .track_focus(&self.herdr_refresh_focus)
                            .tab_index(0)
                            .tab_group()
                            .tab_stop(true)
                            .focus_visible(|style| style.bg(theme.overlay_strong))
                            .px(px(10.0))
                            .py(px(6.0))
                            .rounded(px(7.0))
                            .cursor_default()
                            .text_size(sp(12.0))
                            .bg(theme.overlay)
                            .child(if self.herdr_loading {
                                "Loading…"
                            } else {
                                "Refresh"
                            })
                            .on_click(cx.listener(|this, _, _, cx| this.refresh_herdr_state(cx)))
                            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                    this.refresh_herdr_state(cx);
                                    cx.stop_propagation();
                                }
                            })),
                    ),
            )
            .when_some(self.herdr_error.clone(), |element, error| {
                element.child(
                    div()
                        .p(px(10.0))
                        .rounded(px(8.0))
                        .bg(theme.danger_soft)
                        .text_size(sp(12.0))
                        .text_color(theme.danger)
                        .child(error),
                )
            })
            .child(
                div()
                    .flex()
                    .gap(px(14.0))
                    .child(div().w(px(240.0)).flex_none().child(agents))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(10.0))
                            .child(
                                div()
                                    .id("herdr-output-scroll")
                                    .h(px(360.0))
                                    .overflow_y_scroll()
                                    .p(px(12.0))
                                    .rounded(px(8.0))
                                    .bg(rgb(0x111111))
                                    .font_family(".SystemUIFontMonospaced")
                                    .text_size(sp(11.0))
                                    .text_color(rgb(0xe7e7e7))
                                    .child(output),
                            )
                            .when(selected.is_some(), |element| {
                                element
                                    .child(TextField::new(
                                        "herdr-prompt-field",
                                        self.herdr_prompt_input.clone(),
                                    ))
                                    .child(
                                        div()
                                            .flex()
                                            .justify_end()
                                            .gap(px(8.0))
                                            .child(
                                                div()
                                                    .id("herdr-escape")
                                                    .track_focus(&self.herdr_escape_focus)
                                                    .tab_index(0)
                                                    .tab_group()
                                                    .tab_stop(true)
                                                    .focus_visible(|style| {
                                                        style.bg(theme.overlay_strong)
                                                    })
                                                    .px(px(10.0))
                                                    .py(px(6.0))
                                                    .rounded(px(7.0))
                                                    .bg(theme.overlay)
                                                    .cursor_default()
                                                    .text_size(sp(12.0))
                                                    .child("Escape")
                                                    .on_click(cx.listener(|this, _, _, cx| {
                                                        this.send_herdr_keys(vec!["esc".into()], cx)
                                                    }))
                                                    .on_key_down(cx.listener(
                                                        |this, event: &KeyDownEvent, _, cx| {
                                                            if matches!(
                                                                event.keystroke.key.as_str(),
                                                                "enter" | "space"
                                                            ) {
                                                                this.send_herdr_keys(
                                                                    vec!["esc".into()],
                                                                    cx,
                                                                );
                                                                cx.stop_propagation();
                                                            }
                                                        },
                                                    )),
                                            )
                                            .child(
                                                div()
                                                    .id("herdr-interrupt")
                                                    .track_focus(&self.herdr_interrupt_focus)
                                                    .tab_index(0)
                                                    .tab_group()
                                                    .tab_stop(true)
                                                    .focus_visible(|style| {
                                                        style.bg(theme.overlay_strong)
                                                    })
                                                    .px(px(10.0))
                                                    .py(px(6.0))
                                                    .rounded(px(7.0))
                                                    .bg(theme.overlay)
                                                    .cursor_default()
                                                    .text_size(sp(12.0))
                                                    .child("Interrupt")
                                                    .on_click(cx.listener(|this, _, _, cx| {
                                                        this.send_herdr_keys(
                                                            vec!["ctrl+c".into()],
                                                            cx,
                                                        )
                                                    }))
                                                    .on_key_down(cx.listener(
                                                        |this, event: &KeyDownEvent, _, cx| {
                                                            if matches!(
                                                                event.keystroke.key.as_str(),
                                                                "enter" | "space"
                                                            ) {
                                                                this.send_herdr_keys(
                                                                    vec!["ctrl+c".into()],
                                                                    cx,
                                                                );
                                                                cx.stop_propagation();
                                                            }
                                                        },
                                                    )),
                                            )
                                            .child(
                                                div()
                                                    .id("herdr-send")
                                                    .track_focus(&self.herdr_send_focus)
                                                    .tab_index(0)
                                                    .tab_group()
                                                    .tab_stop(true)
                                                    .focus_visible(|style| {
                                                        style.bg(theme.overlay_strong)
                                                    })
                                                    .px(px(12.0))
                                                    .py(px(6.0))
                                                    .rounded(px(7.0))
                                                    .bg(theme.accent)
                                                    .cursor_default()
                                                    .text_size(sp(12.0))
                                                    .text_color(theme.on_inverse)
                                                    .child("Send")
                                                    .on_click(cx.listener(|this, _, _, cx| {
                                                        this.send_herdr_prompt(cx)
                                                    }))
                                                    .on_key_down(cx.listener(
                                                        |this, event: &KeyDownEvent, _, cx| {
                                                            if matches!(
                                                                event.keystroke.key.as_str(),
                                                                "enter" | "space"
                                                            ) {
                                                                this.send_herdr_prompt(cx);
                                                                cx.stop_propagation();
                                                            }
                                                        },
                                                    )),
                                            ),
                                    )
                            }),
                    ),
            )
            .into_any_element()
    }
}

fn herdr_status_color(status: shidou_client::HerdrAgentStatus, theme: &Theme) -> Hsla {
    match status {
        shidou_client::HerdrAgentStatus::Working => theme.gauge,
        shidou_client::HerdrAgentStatus::Blocked => theme.warning,
        shidou_client::HerdrAgentStatus::Done => theme.success,
        shidou_client::HerdrAgentStatus::Idle | shidou_client::HerdrAgentStatus::Unknown => {
            theme.text_tertiary
        }
    }
}

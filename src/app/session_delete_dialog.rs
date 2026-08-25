//! Modal confirmation for removing one or more tasks from the sidebar.
//!
//! Removal is irreversible: it drops the session row, deletes the workspace's
//! session refs, and sweeps the orphaned blobs. The context menu made that a
//! deliberate two-step gesture; Shift-selection and a single keystroke do not,
//! so both routes land here first.

use gpui::{KeyBinding, actions};

use super::sidebar::localized_session_title;
use super::*;

actions!(
    shidou_session_delete,
    [ConfirmSessionDelete, DismissSessionDelete]
);

const DIALOG_CONTEXT: &str = "SessionDeleteDialog";

/// How many task titles the card lists before collapsing the rest into a
/// count. Enough to recognize a mis-click, short enough to stay a dialog.
const MAX_LISTED_TITLES: usize = 6;

pub fn init(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("enter", ConfirmSessionDelete, Some(DIALOG_CONTEXT)),
        KeyBinding::new("escape", DismissSessionDelete, Some(DIALOG_CONTEXT)),
    ]);
}

pub(super) struct SessionDeleteDialogState {
    /// Removal order, in sidebar order, with the active task last so the
    /// select-next dance in `remove_session` runs exactly once.
    sessions: Vec<Uuid>,
    titles: Vec<SharedString>,
    remove_focus: FocusHandle,
    cancel_focus: FocusHandle,
}

impl Shidou {
    /// Ask before removing `sessions`. Sessions that no longer exist are
    /// dropped, and an empty request opens nothing.
    pub(super) fn confirm_session_removal(
        &mut self,
        sessions: Vec<Uuid>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.session_delete_dialog.is_some() {
            return;
        }
        let mut sessions = sessions
            .into_iter()
            .filter(|id| self.state.sessions.iter().any(|session| &session.id == id))
            .collect::<Vec<_>>();
        // The active task removes last: every earlier removal then leaves the
        // selection untouched, so the transcript switches once instead of
        // hopping through each task on its way out.
        if let Some(selected) = self.state.selected_session
            && let Some(index) = sessions.iter().position(|id| *id == selected)
        {
            let selected = sessions.remove(index);
            sessions.push(selected);
        }
        if sessions.is_empty() {
            return;
        }
        let titles = sessions
            .iter()
            .take(MAX_LISTED_TITLES)
            .filter_map(|id| {
                self.state
                    .sessions
                    .iter()
                    .find(|session| &session.id == id)
                    .map(|session| SharedString::from(localized_session_title(session)))
            })
            .collect();
        let remove_focus = cx.focus_handle();
        let focus = remove_focus.clone();
        self.session_delete_dialog = Some(SessionDeleteDialogState {
            sessions,
            titles,
            remove_focus,
            cancel_focus: cx.focus_handle(),
        });
        // Like the commit modal, this surface joins the dispatch tree only
        // after it has drawn; focus it two frames later so Return cannot fall
        // through to whatever was focused beneath it.
        window.on_next_frame(move |window, _| {
            window.on_next_frame(move |window, cx| window.focus(&focus, cx));
        });
        cx.notify();
    }

    fn close_session_delete_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.session_delete_dialog.take().is_none() {
            return;
        }
        let focus = self.composer_focus(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    fn commit_session_removal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(dialog) = self.session_delete_dialog.take() else {
            return;
        };
        for session_id in dialog.sessions {
            self.sidebar_selection.remove(&session_id);
            self.remove_session(session_id, cx);
        }
        self.sidebar_selection.clear();
        self.sidebar_selection_anchor = None;
        let focus = self.composer_focus(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    pub(super) fn render_session_delete_dialog(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let dialog = self.session_delete_dialog.as_ref()?;
        let theme = Theme::current(cx);
        let count = dialog.sessions.len();
        let overflow = count.saturating_sub(dialog.titles.len());
        let titles = dialog.titles.clone();

        let card = div()
            .id("session-delete-card")
            .key_context(DIALOG_CONTEXT)
            .on_action(cx.listener(|shidou, _: &ConfirmSessionDelete, window, cx| {
                shidou.commit_session_removal(window, cx);
            }))
            .on_action(cx.listener(|shidou, _: &DismissSessionDelete, window, cx| {
                shidou.close_session_delete_dialog(window, cx);
            }))
            .tab_group()
            .tab_stop(false)
            .w_full()
            .max_w(px(380.0))
            .overflow_hidden()
            .rounded(px(18.0))
            .bg(theme.composer)
            .shadow_xl()
            .flex()
            .flex_col()
            .p(px(18.0))
            .gap(px(10.0))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(9.0))
                    .text_size(sp(14.5))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child(icon("icons/trash.svg", 15.0, theme.danger))
                    .child(if count == 1 {
                        tr!("session.remove_one_title")
                    } else {
                        tr!("session.remove_many_title", count = count)
                    }),
            )
            .child(
                div()
                    .text_size(sp(13.0))
                    .line_height(sp(18.0))
                    .text_color(theme.text_secondary)
                    .child(tr!("session.remove_body")),
            )
            .child(
                // Titles are ordinary prose, so they read as a list of
                // names rather than a quoted block: a marker per row and
                // room to breathe, not a filled panel of stacked lines.
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.0))
                    .text_size(sp(13.0))
                    .line_height(sp(17.0))
                    .text_color(theme.text_secondary)
                    .children(titles.into_iter().map(|title| {
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.0))
                            .child(
                                div()
                                    .flex_none()
                                    .size(px(3.0))
                                    .rounded_full()
                                    .bg(theme.text_ghost),
                            )
                            .child(div().min_w_0().truncate().child(title))
                            .into_any_element()
                    }))
                    .when(overflow > 0, |list| {
                        list.child(
                            div()
                                .pl(px(11.0))
                                .text_color(theme.text_ghost)
                                .child(tr!("session.remove_overflow", count = overflow)),
                        )
                    }),
            )
            .child(
                div()
                    .mt(px(2.0))
                    .flex()
                    .items_center()
                    .justify_end()
                    .gap(px(8.0))
                    .child(render_dialog_button(
                        "session-delete-cancel",
                        &dialog.cancel_focus,
                        tr!("common.cancel"),
                        false,
                        cx.listener(|shidou, _: &(), window, cx| {
                            shidou.close_session_delete_dialog(window, cx);
                        }),
                        &theme,
                    ))
                    .child(render_dialog_button(
                        "session-delete-confirm",
                        &dialog.remove_focus,
                        tr!("common.remove"),
                        true,
                        cx.listener(|shidou, _: &(), window, cx| {
                            shidou.commit_session_removal(window, cx);
                        }),
                        &theme,
                    )),
            );

        let scrim = if theme.is_dark {
            gpui::hsla(0.0, 0.0, 0.0, 0.34)
        } else {
            gpui::hsla(0.0, 0.0, 0.0, 0.16)
        };
        let layer = div()
            .id("session-delete-layer")
            .absolute()
            .inset_0()
            .occlude()
            .bg(scrim)
            .p(px(24.0))
            .flex()
            .items_center()
            .justify_center()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|shidou, _, window, cx| shidou.close_session_delete_dialog(window, cx)),
            )
            .child(card);
        Some(gpui::deferred(layer).with_priority(4).into_any_element())
    }
}

pub(super) fn render_dialog_button(
    id: &'static str,
    focus: &FocusHandle,
    label: String,
    danger: bool,
    activate: impl Fn(&(), &mut Window, &mut App) + 'static,
    theme: &Theme,
) -> Stateful<Div> {
    let activate = Rc::new(activate);
    let key_activate = activate.clone();
    let foreground = if danger { theme.danger } else { theme.text };
    div()
        .id(id)
        .track_focus(focus)
        .tab_index(0)
        .h(px(30.0))
        .px(px(12.0))
        .rounded(px(8.0))
        .border_1()
        .border_color(if danger {
            theme.danger.opacity(0.5)
        } else {
            theme.border_strong
        })
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .cursor_default()
        .text_size(sp(13.0))
        .text_color(foreground)
        .focus_visible(|style| style.border_color(theme.accent))
        .hover(|style| {
            style.bg(if danger {
                theme.danger.opacity(0.12)
            } else {
                theme.overlay_strong
            })
        })
        .child(label)
        .on_click(move |_, window, cx| activate(&(), window, cx))
        .on_key_down(move |event: &KeyDownEvent, window, cx| {
            if !event.keystroke.modifiers.modified()
                && matches!(event.keystroke.key.as_str(), "enter" | "space")
            {
                key_activate(&(), window, cx);
                cx.stop_propagation();
            }
        })
}

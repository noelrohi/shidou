//! Confirmation before a user closes a live terminal surface.

use gpui::{KeyBinding, actions};

use super::session_delete_dialog::render_dialog_button;
use super::*;

actions!(
    shidou_terminal_close,
    [ConfirmTerminalClose, DismissTerminalClose]
);

const DIALOG_CONTEXT: &str = "TerminalCloseDialog";

pub fn init(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("enter", ConfirmTerminalClose, Some(DIALOG_CONTEXT)),
        KeyBinding::new("escape", DismissTerminalClose, Some(DIALOG_CONTEXT)),
    ]);
}

pub(super) struct TerminalCloseDialogState {
    terminal_id: Uuid,
    title: SharedString,
    close_focus: FocusHandle,
    cancel_focus: FocusHandle,
}

impl Shidou {
    pub(super) fn request_close_right_panel_surface(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(surface) = self.right_panel_surfaces.get(index) else {
            return;
        };
        let Some(terminal_id) = surface.terminal_id() else {
            self.close_right_panel_surface(index, cx);
            return;
        };
        let Some(terminal) = self.right_panel_terminals.get(&terminal_id) else {
            self.close_right_panel_surface(index, cx);
            return;
        };
        if !terminal.read(cx).requires_close_confirmation() {
            self.close_right_panel_surface(index, cx);
            return;
        }
        if self.terminal_close_dialog.is_some() {
            return;
        }

        let close_focus = cx.focus_handle();
        let focus = close_focus.clone();
        self.terminal_close_dialog = Some(TerminalCloseDialogState {
            terminal_id,
            title: terminal.read(cx).title().to_owned().into(),
            close_focus,
            cancel_focus: cx.focus_handle(),
        });
        window.on_next_frame(move |window, _| {
            window.on_next_frame(move |window, cx| window.focus(&focus, cx));
        });
        cx.notify();
    }

    fn dismiss_terminal_close_dialog(&mut self, cx: &mut Context<Self>) {
        if self.terminal_close_dialog.take().is_none() {
            return;
        }
        self.request_active_terminal_focus();
        cx.notify();
    }

    fn confirm_terminal_close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(dialog) = self.terminal_close_dialog.take() else {
            return;
        };
        if let Some(index) = self
            .right_panel_surfaces
            .iter()
            .position(|surface| surface.terminal_id() == Some(dialog.terminal_id))
        {
            self.close_right_panel_surface(index, cx);
        }
        if self.right_panel_surfaces.is_empty() {
            let focus = self.composer_focus(cx);
            window.focus(&focus, cx);
        } else {
            self.request_active_terminal_focus();
        }
        cx.notify();
    }

    pub(super) fn render_terminal_close_dialog(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let dialog = self.terminal_close_dialog.as_ref()?;
        let theme = Theme::current(cx);
        let title = dialog.title.clone();

        let card = div()
            .id("terminal-close-card")
            .key_context(DIALOG_CONTEXT)
            .on_action(cx.listener(|shidou, _: &ConfirmTerminalClose, window, cx| {
                shidou.confirm_terminal_close(window, cx);
            }))
            .on_action(cx.listener(|shidou, _: &DismissTerminalClose, _, cx| {
                shidou.dismiss_terminal_close_dialog(cx);
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
                    .child(icon("icons/terminal.svg", 15.0, theme.danger))
                    .child(tr!("terminal.close_title", title = title)),
            )
            .child(
                div()
                    .text_size(sp(13.0))
                    .line_height(sp(18.0))
                    .text_color(theme.text_secondary)
                    .child(tr!("terminal.close_body")),
            )
            .child(
                div()
                    .mt(px(2.0))
                    .flex()
                    .items_center()
                    .justify_end()
                    .gap(px(8.0))
                    .child(render_dialog_button(
                        "terminal-close-cancel",
                        &dialog.cancel_focus,
                        tr!("common.cancel"),
                        false,
                        cx.listener(|shidou, _: &(), _, cx| {
                            shidou.dismiss_terminal_close_dialog(cx);
                        }),
                        &theme,
                    ))
                    .child(render_dialog_button(
                        "terminal-close-confirm",
                        &dialog.close_focus,
                        tr!("common.close"),
                        true,
                        cx.listener(|shidou, _: &(), window, cx| {
                            shidou.confirm_terminal_close(window, cx);
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
            .id("terminal-close-layer")
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
                cx.listener(|shidou, _, _, cx| shidou.dismiss_terminal_close_dialog(cx)),
            )
            .child(card);
        Some(gpui::deferred(layer).with_priority(4).into_any_element())
    }
}

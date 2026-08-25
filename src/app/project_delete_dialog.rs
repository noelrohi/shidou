//! Modal confirmation for removing a project from the sidebar.
//!
//! A project carries its whole task history: transcripts, saved state, and the
//! checkpoint refs each task wrote into the checkout. One menu click is a very
//! small gesture for that much, so it lands here first. No working-tree file is
//! touched — the only thing removed from the checkout is the Git refs Shidou
//! wrote there itself.

use gpui::{KeyBinding, actions};

use super::session_delete_dialog::render_dialog_button;
use super::settings::abbreviate_home_path;
use super::*;

actions!(
    shidou_project_delete,
    [ConfirmProjectDelete, DismissProjectDelete]
);

const DIALOG_CONTEXT: &str = "ProjectDeleteDialog";

pub fn init(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("enter", ConfirmProjectDelete, Some(DIALOG_CONTEXT)),
        KeyBinding::new("escape", DismissProjectDelete, Some(DIALOG_CONTEXT)),
    ]);
}

pub(super) struct ProjectDeleteDialogState {
    project_id: Uuid,
    name: SharedString,
    path: SharedString,
    /// Started tasks that leave with the project. Drafts are excluded: an
    /// untouched project always holds one, and counting it would invent a loss
    /// the user does not have.
    started_task_count: usize,
    remove_focus: FocusHandle,
    cancel_focus: FocusHandle,
}

impl Shidou {
    /// Ask before removing `project_id`. A project that no longer exists, and
    /// the projectless scratch project — which is bookkeeping for a single
    /// task and is pruned with it — open nothing.
    pub(super) fn confirm_project_removal(
        &mut self,
        project_id: Uuid,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.project_delete_dialog.is_some() {
            return;
        }
        let Some(project) = self
            .state
            .projects
            .iter()
            .find(|project| project.id == project_id)
            .filter(|project| !project.is_projectless())
        else {
            return;
        };
        let name = SharedString::from(project.display_name());
        let path = SharedString::from(abbreviate_home_path(
            &project.path,
            self.home_directory.as_deref(),
        ));
        let started_task_count = self
            .state
            .sessions
            .iter()
            .filter(|session| session.project_id == project_id && session.has_started())
            .count();
        let remove_focus = cx.focus_handle();
        let focus = remove_focus.clone();
        self.project_delete_dialog = Some(ProjectDeleteDialogState {
            project_id,
            name,
            path,
            started_task_count,
            remove_focus,
            cancel_focus: cx.focus_handle(),
        });
        // Like the task removal modal, this surface joins the dispatch tree
        // only after it has drawn; focus it two frames later so Return cannot
        // fall through to whatever was focused beneath it.
        window.on_next_frame(move |window, _| {
            window.on_next_frame(move |window, cx| window.focus(&focus, cx));
        });
        cx.notify();
    }

    fn close_project_delete_dialog(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.project_delete_dialog.take().is_none() {
            return;
        }
        self.refocus_composer_after_project_dialog(window, cx);
    }

    fn commit_project_removal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(dialog) = self.project_delete_dialog.take() else {
            return;
        };
        self.remove_project(dialog.project_id, cx);
        self.refocus_composer_after_project_dialog(window, cx);
    }

    fn refocus_composer_after_project_dialog(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let focus = self.composer_focus(cx);
        window.focus(&focus, cx);
        cx.notify();
    }

    pub(super) fn render_project_delete_dialog(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let dialog = self.project_delete_dialog.as_ref()?;
        let theme = Theme::current(cx);
        let name = dialog.name.clone();
        let path = dialog.path.clone();
        let task_count_line = match dialog.started_task_count {
            0 => None,
            1 => Some(SharedString::from(tr!("project.remove_one_task"))),
            count => Some(SharedString::from(tr!(
                "project.remove_many_tasks",
                count = count
            ))),
        };

        let card =
            div()
                .id("project-delete-card")
                .key_context(DIALOG_CONTEXT)
                .on_action(cx.listener(|shidou, _: &ConfirmProjectDelete, window, cx| {
                    shidou.commit_project_removal(window, cx);
                }))
                .on_action(cx.listener(|shidou, _: &DismissProjectDelete, window, cx| {
                    shidou.close_project_delete_dialog(window, cx);
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
                        // Unlike the list rows below, the title is not truncated:
                        // clipping it would drop the closing quote and question mark
                        // and leave the sentence reading as a fragment.
                        .child(
                            div()
                                .min_w_0()
                                .child(tr!("project.remove_title", name = name)),
                        ),
                )
                .child(
                    div()
                        .text_size(sp(13.0))
                        .line_height(sp(18.0))
                        .text_color(theme.text_secondary)
                        // A project with nothing in it loses nothing but itself,
                        // so the body must not claim saved tasks and checkpoints
                        // are going with it.
                        .child(if dialog.started_task_count == 0 {
                            tr!("project.remove_body_empty")
                        } else {
                            tr!("project.remove_body")
                        }),
                )
                .child(
                    // The folder and the task count read as a short list of what
                    // is at stake, matching the task removal modal's prose rows
                    // rather than a filled panel.
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(6.0))
                        .text_size(sp(13.0))
                        .line_height(sp(17.0))
                        .text_color(theme.text_secondary)
                        .children([Some(path), task_count_line].into_iter().flatten().map(
                            |line| {
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
                                    .child(div().min_w_0().truncate().child(line))
                            },
                        )),
                )
                .child(
                    div()
                        .mt(px(2.0))
                        .flex()
                        .items_center()
                        .justify_end()
                        .gap(px(8.0))
                        .child(render_dialog_button(
                            "project-delete-cancel",
                            &dialog.cancel_focus,
                            tr!("common.cancel"),
                            false,
                            cx.listener(|shidou, _: &(), window, cx| {
                                shidou.close_project_delete_dialog(window, cx);
                            }),
                            &theme,
                        ))
                        .child(render_dialog_button(
                            "project-delete-confirm",
                            &dialog.remove_focus,
                            tr!("common.remove"),
                            true,
                            cx.listener(|shidou, _: &(), window, cx| {
                                shidou.commit_project_removal(window, cx);
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
            .id("project-delete-layer")
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
                cx.listener(|shidou, _, window, cx| shidou.close_project_delete_dialog(window, cx)),
            )
            .child(card);
        Some(gpui::deferred(layer).with_priority(4).into_any_element())
    }
}

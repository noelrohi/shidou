//! Workspace-folder image gallery for the singleton Visuals surface.
//!
//! The coding agent creates image files in the workspace. Visuals only indexes,
//! previews, selects, and attaches those files; it owns no generation lifecycle.

use super::*;

const VISUAL_GALLERY_GAP: f32 = 6.0;
const VISUAL_GALLERY_CAP: usize = 50_000;

impl VisualGalleryLayout {
    fn label(self) -> String {
        match self {
            Self::Compact => tr!("visuals.layout_compact"),
            Self::Large => tr!("visuals.layout_large"),
            Self::Fit => tr!("visuals.layout_fit"),
        }
    }
}

fn supported_visual_path(path: &str) -> bool {
    path_extension_lowercase(path)
        .as_deref()
        .is_some_and(|extension| waku_protocol::VISUAL_IMAGE_EXTENSIONS.contains(&extension))
}

fn visual_folder(path: &str) -> String {
    Path::new(path)
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map(|parent| parent.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn visual_columns(width: f32, layout: VisualGalleryLayout) -> usize {
    if layout == VisualGalleryLayout::Fit {
        return 1;
    }
    let target = if layout == VisualGalleryLayout::Compact {
        waku_protocol::VISUAL_COMPACT_COLUMN_WIDTH
    } else {
        waku_protocol::VISUAL_LARGE_COLUMN_WIDTH
    };
    (((width - waku_protocol::VISUAL_GRID_HORIZONTAL_INSET).max(1.0) / target).floor() as usize)
        .max(1)
}

impl Waku {
    pub(super) fn refresh_visual_gallery(&mut self, cx: &mut Context<Self>) {
        let Some(workspace_path) = self.selected_workspace_path().map(Path::to_path_buf) else {
            self.visual_gallery.clear();
            cx.notify();
            return;
        };

        if self.visual_gallery.workspace.as_ref() != Some(&workspace_path) {
            self.visual_gallery.workspace = Some(workspace_path.clone());
            self.visual_gallery.clear_folder();
        }
        self.visual_gallery.generation = self.visual_gallery.generation.wrapping_add(1);
        let generation = self.visual_gallery.generation;
        // Refresh quietly when something is already on screen: keep drawing
        // the current gallery and swap in the fresh result when it lands,
        // the way the working-tree surface does. The spinner is only for a
        // gallery with nothing to show yet.
        if self.visual_gallery.images.is_empty() {
            self.visual_gallery.loading = true;
        }
        let workspace = waku_client::WorkspaceClient::new(self.daemon.client());
        cx.spawn(async move |waku, cx| {
            let result = cx
                .background_executor()
                .spawn({
                    let root = workspace_path.clone();
                    async move {
                        workspace.request(waku_client::WorkspaceOperation::ListProjectFiles {
                            root,
                            cap: VISUAL_GALLERY_CAP,
                        })
                    }
                })
                .await;
            let _ = waku.update(cx, |this, cx| {
                if this.visual_gallery.generation != generation
                    || this.visual_gallery.workspace.as_ref() != Some(&workspace_path)
                {
                    return;
                }
                let mut index: HashMap<String, Vec<VisualGalleryFile>> = HashMap::new();
                match result {
                    Ok(waku_client::WorkspaceResult::ProjectFiles { entries }) => {
                        if entries.len() >= VISUAL_GALLERY_CAP {
                            eprintln!(
                                "visual gallery file listing hit its cap of \
                                 {VISUAL_GALLERY_CAP} entries; some images may be missing"
                            );
                        }
                        for entry in entries {
                            if entry.is_dir || !supported_visual_path(&entry.path) {
                                continue;
                            }
                            let name = Path::new(&entry.path)
                                .file_name()
                                .and_then(|name| name.to_str())
                                .unwrap_or(&entry.path)
                                .to_owned();
                            index.entry(visual_folder(&entry.path)).or_default().push(
                                VisualGalleryFile {
                                    absolute_path: workspace_path.join(&entry.path),
                                    relative_path: entry.path,
                                    name,
                                },
                            );
                        }
                        for files in index.values_mut() {
                            files.sort_by(|left, right| {
                                left.relative_path.cmp(&right.relative_path)
                            });
                        }
                        this.visual_gallery.load_error = None;
                    }
                    Ok(_) => {
                        this.visual_gallery.load_error =
                            Some(tr!("visuals.load_failed", error = "unexpected response"));
                    }
                    Err(error) => {
                        this.visual_gallery.load_error =
                            Some(tr!("visuals.load_failed", error = error.to_string()));
                    }
                }
                this.visual_gallery.index = index;
                if this
                    .visual_gallery
                    .folder
                    .as_ref()
                    .is_some_and(|folder| !this.visual_gallery.index.contains_key(folder))
                {
                    this.visual_gallery.clear_folder();
                }
                this.visual_gallery.loading = false;
                let selected = this.visual_gallery.folder.clone();
                if let Some(folder) = selected {
                    this.load_visual_gallery_folder(folder, true, cx);
                } else {
                    this.visual_gallery.list_state.reset(0);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn select_visual_gallery_folder(&mut self, folder: String, cx: &mut Context<Self>) {
        if self.visual_gallery.folder.as_deref() == Some(folder.as_str()) {
            return;
        }
        self.visual_gallery.folder = Some(folder.clone());
        self.visual_gallery.selected.clear();
        self.load_visual_gallery_folder(folder, false, cx);
    }

    /// A quiet load keeps the current images and scroll position on screen
    /// until the fresh set lands — used by refocus-driven refreshes, where
    /// blanking an unchanged gallery reads as a spurious reload.
    fn load_visual_gallery_folder(&mut self, folder: String, quiet: bool, cx: &mut Context<Self>) {
        let Some(files) = self.visual_gallery.index.get(&folder).cloned() else {
            self.visual_gallery.images.clear();
            self.visual_gallery.loading = false;
            self.visual_gallery.list_state.reset(0);
            cx.notify();
            return;
        };
        self.visual_gallery.generation = self.visual_gallery.generation.wrapping_add(1);
        let generation = self.visual_gallery.generation;
        if !quiet {
            self.visual_gallery.images.clear();
            self.visual_gallery.loading = true;
            self.visual_gallery.list_state.reset(0);
        }
        let daemon = self.daemon.clone();
        cx.spawn(async move |waku, cx| {
            let images = cx
                .background_executor()
                .spawn(async move {
                    // One background pass and one round trip for the whole
                    // folder; a file the daemon cannot import comes back as
                    // `None` in its slot and is skipped.
                    let response = daemon.client().request(
                        Uuid::nil(),
                        Uuid::nil(),
                        waku_client::Command::ImportPathAttachments {
                            paths: files
                                .iter()
                                .map(|file| file.absolute_path.clone())
                                .collect(),
                        },
                    );
                    let attachments = match response {
                        Ok(waku_client::ResponsePayload::AttachmentsStored { attachments }) => {
                            attachments
                        }
                        Ok(_) => return Err("unexpected response".to_string()),
                        Err(error) => return Err(error.to_string()),
                    };
                    Ok(files
                        .into_iter()
                        .zip(attachments)
                        .filter_map(|(file, attachment)| {
                            attachment.map(|attachment| VisualGalleryImage {
                                relative_path: file.relative_path,
                                stored_path: attachment.path,
                                name: file.name,
                                reference: attachment.reference,
                            })
                        })
                        .collect::<Vec<_>>())
                })
                .await;
            let _ = waku.update(cx, |this, cx| {
                if this.visual_gallery.generation != generation
                    || this.visual_gallery.folder.as_deref() != Some(folder.as_str())
                {
                    return;
                }
                let images = match images {
                    Ok(images) => {
                        this.visual_gallery.load_error = None;
                        images
                    }
                    Err(error) => {
                        this.visual_gallery.load_error =
                            Some(tr!("visuals.load_failed", error = error));
                        this.visual_gallery.loading = false;
                        cx.notify();
                        return;
                    }
                };
                let unchanged = this.visual_gallery.images.len() == images.len()
                    && this
                        .visual_gallery
                        .images
                        .iter()
                        .zip(&images)
                        .all(|(old, new)| old.relative_path == new.relative_path);
                this.visual_gallery.images = images;
                let images = &this.visual_gallery.images;
                this.visual_gallery
                    .selected
                    .retain(|path| images.iter().any(|image| image.relative_path == *path));
                this.visual_gallery.loading = false;
                // Resetting the list drops the scroll position; only pay
                // that when the set of images actually changed.
                if !unchanged {
                    let rows = this
                        .visual_gallery
                        .images
                        .len()
                        .div_ceil(this.visual_gallery.columns.max(1));
                    this.visual_gallery.list_state.reset(rows);
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn set_visual_gallery_layout(&mut self, layout: VisualGalleryLayout, cx: &mut Context<Self>) {
        if self.visual_gallery.layout == layout {
            return;
        }
        self.visual_gallery.layout = layout;
        self.visual_gallery.columns = 0;
        cx.notify();
    }

    fn toggle_visual_gallery_selection(&mut self, path: String, cx: &mut Context<Self>) {
        if !self.visual_gallery.selected.remove(&path) {
            self.visual_gallery.selected.insert(path);
        }
        cx.notify();
    }

    /// Mirrored by `visualGridIndex` in
    /// `apps/web/src/lib/visuals-presentation.ts`; keep the movement rules in
    /// sync.
    fn move_visual_gallery_focus(
        &self,
        current: usize,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let count = self.visual_gallery.images.len();
        if count == 0 {
            return false;
        }
        let columns = self.visual_gallery.columns.max(1);
        let target = match key {
            "left" => current.saturating_sub(1),
            "right" => (current + 1).min(count - 1),
            "up" => current.saturating_sub(columns),
            "down" => (current + columns).min(count - 1),
            "home" => 0,
            "end" => count - 1,
            _ => return false,
        };
        self.visual_gallery
            .list_state
            .scroll_to_reveal_item(target / columns);
        let focus = self.transcript_control_focus(format!("visual-gallery-card-{target}"), cx);
        window.on_next_frame(move |window, cx| window.focus(&focus, cx));
        cx.notify();
        true
    }

    fn attach_visual_gallery_selection(&mut self, cx: &mut Context<Self>) {
        if self.visual_gallery.selected.is_empty() {
            self.show_toast(tr!("visuals.select_first"));
            return;
        }
        let selected = self
            .visual_gallery
            .images
            .iter()
            .filter(|image| self.visual_gallery.selected.contains(&image.relative_path))
            .cloned()
            .collect::<Vec<_>>();
        let mut attached = 0;
        for image in selected {
            let reference = image.reference.clone();
            attached += usize::from(self.stage_daemon_attachment(
                image.stored_path,
                image.name,
                false,
                true,
                reference.clone(),
                None,
            ));
            if let Some(attachment) = self
                .composer_attachments
                .iter_mut()
                .find(|attachment| attachment.blob_reference.as_deref() == Some(reference.as_str()))
            {
                attachment.mention = image.relative_path;
            }
        }
        if attached > 0 {
            self.schedule_composer_draft_save(cx);
            self.show_success_toast(tr!("visuals.attached", count = attached));
            cx.notify();
        }
    }

    pub(super) fn render_visuals_surface(
        &mut self,
        panel_width: f32,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let theme = Theme::current(cx);
        let folder_menu = self.menu_handle("visuals-folder-menu", cx);
        let layout_menu = self.menu_handle("visuals-layout-menu", cx);
        let mut folders = self
            .visual_gallery
            .index
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        folders.sort();
        let active_folder = self.visual_gallery.folder.clone();
        let weak = cx.entity().downgrade();
        let folder_trigger = MenuChip::new("visuals-folder-trigger")
            .icon("icons/folder.svg", theme.text_ghost)
            .label(active_folder.clone().map_or_else(
                || tr!("visuals.choose_folder"),
                |folder| {
                    if folder.is_empty() {
                        ".".into()
                    } else {
                        folder
                    }
                },
            ))
            .selected(folder_menu.is_open())
            .max_w(px((panel_width * 0.55).max(120.0)));
        let folder_dropdown = dropdown_menu(
            folder_trigger,
            "visuals-folder-dropdown",
            &folder_menu,
            MenuAlign::BelowLeft,
            move |_| {
                folders
                    .iter()
                    .map(|folder| {
                        let weak = weak.clone();
                        let selected_folder = folder.clone();
                        MenuItem::new(
                            if folder.is_empty() {
                                ".".into()
                            } else {
                                folder.clone()
                            },
                            move |_, cx| {
                                let _ = weak.update(cx, |this, cx| {
                                    this.select_visual_gallery_folder(selected_folder.clone(), cx);
                                });
                            },
                        )
                        .selected(active_folder.as_deref() == Some(folder.as_str()))
                        .icon("icons/folder.svg")
                    })
                    .collect()
            },
        );

        let layout = self.visual_gallery.layout;
        let layout_weak = cx.entity().downgrade();
        let layout_trigger = MenuChip::new("visuals-layout-trigger")
            .label(layout.label())
            .selected(layout_menu.is_open());
        let layout_dropdown = dropdown_menu(
            layout_trigger,
            "visuals-layout-dropdown",
            &layout_menu,
            MenuAlign::BelowRight,
            move |_| {
                [
                    VisualGalleryLayout::Compact,
                    VisualGalleryLayout::Large,
                    VisualGalleryLayout::Fit,
                ]
                .into_iter()
                .map(|candidate| {
                    let weak = layout_weak.clone();
                    MenuItem::new(candidate.label(), move |_, cx| {
                        let _ = weak.update(cx, |this, cx| {
                            this.set_visual_gallery_layout(candidate, cx);
                        });
                    })
                    .selected(candidate == layout)
                })
                .collect()
            },
        );

        let toolbar = div()
            .h(px(38.0))
            .flex_none()
            .px(px(8.0))
            .border_b_1()
            .border_color(theme.border)
            .flex()
            .items_center()
            .gap(px(5.0))
            .child(folder_dropdown)
            .child(layout_dropdown)
            .child(div().flex_1())
            .child(self.render_icon_button(
                "visuals-refresh",
                "icons/rotate-cw.svg",
                26.0,
                7.0,
                theme.overlay,
                tr!("visuals.refresh"),
                |this, _, cx| this.refresh_visual_gallery(cx),
                cx,
            ));

        let columns = visual_columns(panel_width, layout);
        if self.visual_gallery.columns != columns {
            self.visual_gallery.columns = columns;
            self.visual_gallery
                .list_state
                .reset(self.visual_gallery.images.len().div_ceil(columns));
        }
        let content = if self.selected_workspace_path().is_none() {
            self.render_visual_gallery_empty(tr!("visuals.no_workspace"), cx)
        } else if self.visual_gallery.loading {
            self.render_visual_gallery_loading(cx)
        } else if let Some(error) = self.visual_gallery.load_error.clone() {
            self.render_visual_gallery_empty(error, cx)
        } else if self.visual_gallery.index.is_empty() {
            self.render_visual_gallery_empty(tr!("visuals.no_folders"), cx)
        } else if self.visual_gallery.folder.is_none() {
            self.render_visual_gallery_empty(tr!("visuals.choose_folder"), cx)
        } else if self.visual_gallery.images.is_empty() {
            self.render_visual_gallery_empty(tr!("visuals.no_images"), cx)
        } else {
            let entity = cx.entity().downgrade();
            let card_width = ((panel_width
                - waku_protocol::VISUAL_GRID_HORIZONTAL_INSET
                - VISUAL_GALLERY_GAP * (columns - 1) as f32)
                / columns as f32)
                .max(80.0);
            div()
                .flex_1()
                .min_h_0()
                .child(
                    list(
                        self.visual_gallery.list_state.clone(),
                        move |row, window, cx| {
                            entity
                                .upgrade()
                                .map(|entity| {
                                    entity.update(cx, |this, cx| {
                                        this.render_visual_gallery_row(
                                            row, columns, card_width, window, cx,
                                        )
                                    })
                                })
                                .unwrap_or_else(|| div().into_any_element())
                        },
                    )
                    .size_full(),
                )
                .into_any_element()
        };

        let selection_count = self.visual_gallery.selected.len();
        let attach_focus = self.transcript_control_focus("visuals-attach-selected", cx);
        let footer = div()
            .min_h(px(46.0))
            .flex_none()
            .px(px(10.0))
            .border_t_1()
            .border_color(theme.border)
            .flex()
            .items_center()
            .gap(px(8.0))
            .child(
                div()
                    .flex_1()
                    .text_size(sp(11.0))
                    .text_color(theme.text_ghost)
                    .child(tr!("visuals.selected_count", count = selection_count)),
            )
            .child(
                div()
                    .id("visuals-attach-selected")
                    .track_focus(&attach_focus)
                    .tab_index(0)
                    .h(px(28.0))
                    .px(px(10.0))
                    .rounded(px(6.0))
                    .bg(if selection_count > 0 {
                        theme.inverse
                    } else {
                        theme.overlay
                    })
                    .text_color(if selection_count > 0 {
                        theme.on_inverse
                    } else {
                        theme.text_ghost
                    })
                    .flex()
                    .items_center()
                    .gap(px(5.0))
                    .text_size(sp(11.5))
                    .font_weight(FontWeight::MEDIUM)
                    .focus_visible(|style| style.border_1().border_color(theme.accent))
                    .when(selection_count > 0, |button| {
                        button
                            .hover(|style| style.opacity(0.9))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.attach_visual_gallery_selection(cx);
                            }))
                            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                    this.attach_visual_gallery_selection(cx);
                                    cx.stop_propagation();
                                }
                            }))
                    })
                    .child(icon(
                        "icons/paperclip.svg",
                        11.0,
                        if selection_count > 0 {
                            theme.on_inverse
                        } else {
                            theme.text_ghost
                        },
                    ))
                    .child(tr!("visuals.attach_selected")),
            );

        div()
            .id("visuals-surface")
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(toolbar)
            .child(content)
            .child(footer)
    }

    fn render_visual_gallery_empty(&self, title: String, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::current(cx);
        div()
            .flex_1()
            .min_h_0()
            .px(px(28.0))
            .pb(px(36.0))
            .flex()
            .items_center()
            .justify_center()
            .child(
                div()
                    .max_w(px(260.0))
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(7.0))
                    .child(icon("icons/folder.svg", 18.0, theme.text_ghost))
                    .child(
                        div()
                            .text_size(sp(12.0))
                            .text_color(theme.text_secondary)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(sp(10.5))
                            .line_height(sp(15.0))
                            .text_color(theme.text_ghost)
                            .child(tr!("visuals.folder_hint")),
                    ),
            )
            .into_any_element()
    }

    fn render_visual_gallery_loading(&self, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::current(cx);
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .items_center()
            .justify_center()
            .gap(px(7.0))
            .text_size(sp(11.5))
            .text_color(theme.text_ghost)
            .child(motion::spin(icon(
                "icons/loader-circle.svg",
                13.0,
                theme.text_ghost,
            )))
            .child(tr!("visuals.loading"))
            .into_any_element()
    }

    fn render_visual_gallery_row(
        &self,
        row: usize,
        columns: usize,
        card_width: f32,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::current(cx);
        let start = row.saturating_mul(columns);
        let end = (start + columns).min(self.visual_gallery.images.len());
        let mut row_view = div()
            .w_full()
            .px(px(8.0))
            .pt(px(if row == 0 { 8.0 } else { 3.0 }))
            .pb(px(3.0))
            .flex()
            .gap(px(VISUAL_GALLERY_GAP));
        for (index, image) in self.visual_gallery.images[start..end].iter().enumerate() {
            let absolute_index = start + index;
            let selected = self.visual_gallery.selected.contains(&image.relative_path);
            let source = self.image_for_reference(
                &image.reference,
                Some(&image.stored_path),
                Some(&image.name),
                cx,
            );
            let click_path = image.relative_path.clone();
            let key_path = image.relative_path.clone();
            let preview_source = source.clone();
            let preview_name = SharedString::from(image.name.clone());
            let preview_click_source = source.clone();
            let preview_click_name = preview_name.clone();
            let preview_key_source = preview_click_source.clone();
            let preview_key_name = preview_name.clone();
            let focus =
                self.transcript_control_focus(format!("visual-gallery-card-{absolute_index}"), cx);
            let image_height = if self.visual_gallery.layout == VisualGalleryLayout::Fit {
                (card_width * 0.72).clamp(160.0, 420.0)
            } else {
                card_width
            };
            // Selection and keyboard focus must stay distinguishable: a
            // selected card gets a strong border plus fill and check icon,
            // while the accent border is reserved for `focus_visible`.
            let mut card = div()
                .id(SharedString::from(format!(
                    "visual-gallery-card-{absolute_index}"
                )))
                .track_focus(&focus)
                .tab_index(0)
                .relative()
                .w(px(card_width))
                .flex_none()
                .p(px(3.0))
                .rounded(px(8.0))
                .border_1()
                .border_color(if selected {
                    theme.border_strong
                } else {
                    theme.border.opacity(0.0)
                })
                .bg(if selected {
                    theme.overlay_strong
                } else {
                    theme.inset
                })
                .focus_visible(|style| style.border_color(theme.accent))
                .hover(|style| style.border_color(theme.border));
            card = card.child(if let Some(source) = source {
                img(source)
                    .w_full()
                    .h(px(image_height))
                    .rounded(px(5.0))
                    .object_fit(if self.visual_gallery.layout == VisualGalleryLayout::Fit {
                        ObjectFit::Contain
                    } else {
                        ObjectFit::Cover
                    })
                    .into_any_element()
            } else {
                div()
                    .w_full()
                    .h(px(image_height))
                    .rounded(px(5.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(motion::spin(icon(
                        "icons/loader-circle.svg",
                        13.0,
                        theme.text_ghost,
                    )))
                    .into_any_element()
            });
            card = card
                .child(
                    div()
                        .h(px(24.0))
                        .px(px(5.0))
                        .flex()
                        .items_center()
                        .gap(px(4.0))
                        .child(
                            div()
                                .min_w_0()
                                .flex_1()
                                .truncate()
                                .text_size(sp(10.5))
                                .text_color(theme.text_tertiary)
                                .child(image.name.clone()),
                        )
                        .when(selected, |row| {
                            row.child(icon("icons/check.svg", 10.0, theme.accent))
                        }),
                )
                .when_some(preview_click_source, |card, preview| {
                    let preview_focus = self.transcript_control_focus(
                        format!("visual-gallery-preview-{absolute_index}"),
                        cx,
                    );
                    card.child(
                        div()
                            .id(SharedString::from(format!(
                                "visual-gallery-preview-{absolute_index}"
                            )))
                            .track_focus(&preview_focus)
                            .tab_index(0)
                            .absolute()
                            .top(px(8.0))
                            .right(px(8.0))
                            .size(px(24.0))
                            .rounded(px(6.0))
                            .bg(theme.surface.opacity(0.82))
                            .flex()
                            .items_center()
                            .justify_center()
                            .hover(|style| style.bg(theme.surface))
                            .focus_visible(|style| style.border_1().border_color(theme.accent))
                            .tooltip(Tooltip::text(tr!(
                                "visuals.preview_image",
                                name = preview_click_name.clone()
                            )))
                            .child(icon("icons/eye.svg", 11.0, theme.text_secondary))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                cx.stop_propagation();
                                this.open_image_preview(
                                    preview.clone(),
                                    preview_click_name.clone(),
                                    window,
                                    cx,
                                );
                            }))
                            .on_key_down(cx.listener(
                                move |this, event: &KeyDownEvent, window, cx| {
                                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                        cx.stop_propagation();
                                        if let Some(source) = preview_key_source.clone() {
                                            this.open_image_preview(
                                                source,
                                                preview_key_name.clone(),
                                                window,
                                                cx,
                                            );
                                        }
                                    }
                                },
                            )),
                    )
                })
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.toggle_visual_gallery_selection(click_path.clone(), cx);
                }))
                .on_key_down(cx.listener(move |this, event: &KeyDownEvent, window, cx| {
                    let key = event.keystroke.key.as_str();
                    if this.move_visual_gallery_focus(absolute_index, key, window, cx) {
                        cx.stop_propagation();
                        return;
                    }
                    match key {
                        "space" => {
                            this.toggle_visual_gallery_selection(key_path.clone(), cx);
                            cx.stop_propagation();
                        }
                        "enter" => {
                            if let Some(source) = preview_source.clone() {
                                this.open_image_preview(source, preview_name.clone(), window, cx);
                            }
                            cx.stop_propagation();
                        }
                        _ => {}
                    }
                }));
            row_view = row_view.child(card);
        }
        row_view.into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_images_and_direct_folders_are_stable() {
        assert!(supported_visual_path("assets/HERO.JPEG"));
        assert!(supported_visual_path("assets/logo.svg"));
        assert!(!supported_visual_path("assets/readme.md"));
        assert_eq!(visual_folder("assets/hero/a.png"), "assets/hero");
        assert_eq!(visual_folder("logo.png"), "");
    }

    #[test]
    fn gallery_layouts_choose_columns_from_available_width() {
        assert_eq!(visual_columns(700.0, VisualGalleryLayout::Compact), 6);
        assert_eq!(visual_columns(700.0, VisualGalleryLayout::Large), 3);
        assert_eq!(visual_columns(700.0, VisualGalleryLayout::Fit), 1);
        assert_eq!(visual_columns(280.0, VisualGalleryLayout::Large), 1);
    }

    /// Guards every render function in this file — including the per-row
    /// builder that runs for each visible card on each frame — against
    /// filesystem or RPC work. Source-level, so IO reached through callees is
    /// out of scope; those paths are covered by the CLAUDE.md render rules.
    #[test]
    fn visual_render_functions_have_no_filesystem_or_rpc_work() {
        let source = include_str!("visuals.rs");
        let start = source
            .find("\n    pub(super) fn render_visuals_surface(")
            .expect("render_visuals_surface must exist in visuals.rs");
        let body = &source[start + 1..];
        let end = body
            .find("\n#[cfg(test)]")
            .expect("render functions must precede the test module");
        let body = &body[..end];
        for forbidden in ["std::fs::", "read_dir", ".request("] {
            assert!(
                !body.contains(forbidden),
                "render must not call {forbidden}"
            );
        }
    }
}

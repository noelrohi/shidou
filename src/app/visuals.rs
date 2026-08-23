//! Workspace-folder image gallery for the singleton Visuals surface.
//!
//! The coding agent creates image files in the workspace. Visuals only indexes,
//! previews, selects, and attaches those files; it owns no generation lifecycle.

use std::collections::BTreeSet;

use super::*;

const VISUAL_GALLERY_GAP: f32 = 6.0;
const VISUAL_GALLERY_CAP: usize = 50_000;
/// Border (2px) plus padding (2px) on each side of a card, around the image.
const VISUAL_CARD_CHROME: f32 = 8.0;
/// Target masonry row heights per layout; rows scale off these to justify.
const VISUAL_MASONRY_COMPACT_ROW: f32 = 110.0;
const VISUAL_MASONRY_LARGE_ROW: f32 = 200.0;

/// Pixel dimensions parsed from an image header, dependency-free so it can
/// run for every fetched gallery image. `None` (unknown container, SVG, or a
/// truncated header) makes the masonry layout fall back to a square slot.
pub(super) fn probe_image_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    let be16 = |offset: usize| -> Option<u32> {
        bytes
            .get(offset..offset + 2)
            .map(|b| u32::from(u16::from_be_bytes([b[0], b[1]])))
    };
    let le16 = |offset: usize| -> Option<u32> {
        bytes
            .get(offset..offset + 2)
            .map(|b| u32::from(u16::from_le_bytes([b[0], b[1]])))
    };
    let be32 = |offset: usize| -> Option<u32> {
        bytes
            .get(offset..offset + 4)
            .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    };
    let le24 = |offset: usize| -> Option<u32> {
        bytes
            .get(offset..offset + 3)
            .map(|b| u32::from(b[0]) | u32::from(b[1]) << 8 | u32::from(b[2]) << 16)
    };
    match bytes {
        [0x89, b'P', b'N', b'G', ..] => Some((be32(16)?, be32(20)?)),
        [b'G', b'I', b'F', b'8', ..] => Some((le16(6)?, le16(8)?)),
        [b'B', b'M', ..] => {
            let read_i32 = |offset: usize| -> Option<i32> {
                bytes
                    .get(offset..offset + 4)
                    .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            };
            Some((read_i32(18)?.unsigned_abs(), read_i32(22)?.unsigned_abs()))
        }
        [b'R', b'I', b'F', b'F', ..] if bytes.get(8..12) == Some(b"WEBP") => {
            match bytes.get(12..16)? {
                b"VP8X" => Some((le24(24)? + 1, le24(27)? + 1)),
                b"VP8 " if bytes.get(23..26) == Some(&[0x9D, 0x01, 0x2A]) => {
                    Some((le16(26)? & 0x3FFF, le16(28)? & 0x3FFF))
                }
                b"VP8L" if bytes.get(20) == Some(&0x2F) => {
                    let b = bytes.get(21..25)?;
                    let width = 1 + (u32::from(b[1] & 0x3F) << 8 | u32::from(b[0]));
                    let height = 1
                        + (u32::from(b[3] & 0x0F) << 10
                            | u32::from(b[2]) << 2
                            | u32::from(b[1] >> 6));
                    Some((width, height))
                }
                _ => None,
            }
        }
        [0xFF, 0xD8, ..] => {
            // Walk JPEG segments to the first start-of-frame marker.
            let mut offset = 2;
            while offset + 9 < bytes.len() {
                if bytes[offset] != 0xFF {
                    return None;
                }
                let marker = bytes[offset + 1];
                if marker == 0xFF {
                    offset += 1;
                    continue;
                }
                if (0xC0..=0xCF).contains(&marker) && ![0xC4, 0xC8, 0xCC].contains(&marker) {
                    return Some((be16(offset + 7)?, be16(offset + 5)?));
                }
                offset += 2 + be16(offset + 2)? as usize;
            }
            None
        }
        _ => None,
    }
}

fn visual_aspect(sizes: &HashMap<String, (u32, u32)>, image: &VisualGalleryImage) -> f32 {
    sizes
        .get(&image.reference)
        .map(|&(width, height)| {
            if height == 0 {
                1.0
            } else {
                width as f32 / height as f32
            }
        })
        .unwrap_or(1.0)
        .clamp(0.35, 3.2)
}

/// Justified masonry: each row is a run of images sharing a height, scaled so
/// their aspect-true widths exactly fill `available`. The final row keeps the
/// target height instead of stretching. Unknown dimensions read as square and
/// the plan rebuilds as real dimensions land.
fn build_visual_row_plan(
    images: &[VisualGalleryImage],
    sizes: &HashMap<String, (u32, u32)>,
    layout: VisualGalleryLayout,
    available: f32,
) -> Vec<VisualGalleryRow> {
    if images.is_empty() {
        return Vec::new();
    }
    if layout == VisualGalleryLayout::Fit {
        return images
            .iter()
            .enumerate()
            .map(|(index, image)| {
                let width = (available - VISUAL_CARD_CHROME).max(80.0);
                let image_height = (width / visual_aspect(sizes, image)).clamp(120.0, 640.0);
                VisualGalleryRow {
                    start: index,
                    image_height,
                    widths: vec![width],
                }
            })
            .collect();
    }
    let target = if layout == VisualGalleryLayout::Compact {
        VISUAL_MASONRY_COMPACT_ROW
    } else {
        VISUAL_MASONRY_LARGE_ROW
    };
    let mut plan = Vec::new();
    let mut start = 0usize;
    let mut aspects: Vec<f32> = Vec::new();
    for (index, image) in images.iter().enumerate() {
        aspects.push(visual_aspect(sizes, image));
        let count = aspects.len() as f32;
        let sum: f32 = aspects.iter().sum();
        let chrome = count * VISUAL_CARD_CHROME + (count - 1.0) * VISUAL_GALLERY_GAP;
        let width_at_target = sum * target + chrome;
        let last = index + 1 == images.len();
        if width_at_target >= available || last {
            let exact = ((available - chrome) / sum).max(40.0);
            let image_height = if width_at_target >= available {
                exact
            } else {
                exact.min(target)
            };
            let widths = aspects.iter().map(|aspect| aspect * image_height).collect();
            plan.push(VisualGalleryRow {
                start,
                image_height,
                widths,
            });
            start = index + 1;
            aspects.clear();
        }
    }
    plan
}

impl VisualGalleryLayout {
    fn label(self) -> String {
        match self {
            Self::Compact => tr!("visuals.layout_compact"),
            Self::Large => tr!("visuals.layout_large"),
            Self::Fit => tr!("visuals.layout_fit"),
        }
    }
}

pub(super) fn supported_visual_path(path: &str) -> bool {
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

/// Whether `key` (a direct image folder from the index) lies at or beneath the
/// selected `folder`. The empty folder is the workspace root and contains
/// everything.
fn visual_folder_contains(folder: &str, key: &str) -> bool {
    folder.is_empty()
        || key == folder
        || (key.len() > folder.len()
            && key.starts_with(folder)
            && key.as_bytes()[folder.len()] == b'/')
}

/// Every selectable folder: the direct image folders plus all of their
/// ancestors up to the workspace root, so a parent like `assets/v3` can be
/// chosen to browse its subfolders together. Sorted component-wise so each
/// folder is immediately followed by its descendants — the order an indented
/// tree needs — which plain string order breaks (`pages-x` < `pages/…`).
fn visual_folder_choices<'a>(keys: impl Iterator<Item = &'a String>) -> Vec<String> {
    let mut folders: BTreeSet<Vec<&str>> = BTreeSet::new();
    for key in keys {
        let mut components = if key.is_empty() {
            Vec::new()
        } else {
            key.split('/').collect::<Vec<_>>()
        };
        loop {
            folders.insert(components.clone());
            if components.pop().is_none() {
                break;
            }
        }
    }
    folders
        .into_iter()
        .map(|components| components.join("/"))
        .collect()
}

/// Tree depth and display name for one folder row: the workspace root is `.`
/// at depth zero, every other folder shows only its own final segment.
fn visual_folder_display(folder: &str) -> (usize, &str) {
    if folder.is_empty() {
        return (0, ".");
    }
    let name = folder.rsplit('/').next().unwrap_or(folder);
    (folder.matches('/').count() + 1, name)
}

impl Waku {
    /// Index of the masonry row containing image `index`, if any.
    fn visual_row_containing(&self, index: usize) -> Option<usize> {
        self.visual_gallery
            .row_plan
            .iter()
            .position(|row| index >= row.start && index < row.start + row.widths.len())
    }

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
                if this.visual_gallery.folder.as_ref().is_some_and(|folder| {
                    !this
                        .visual_gallery
                        .index
                        .keys()
                        .any(|key| visual_folder_contains(folder, key))
                }) {
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

    /// Jump to one workspace image from elsewhere in the app: open the
    /// Visuals surface, switch to the image's folder, and — once its images
    /// land — select it, scroll it into view, and focus its card.
    pub(super) fn reveal_visual_in_gallery(
        &mut self,
        relative_path: String,
        cx: &mut Context<Self>,
    ) {
        let folder = visual_folder(&relative_path);
        if self.visual_gallery.folder.as_deref() != Some(folder.as_str()) {
            self.visual_gallery.folder = Some(folder.clone());
            self.visual_gallery.selected.clear();
            self.load_visual_gallery_folder(folder, false, cx);
        }
        self.visual_gallery.selected.insert(relative_path.clone());
        self.visual_gallery.pending_reveal = Some(relative_path);
        self.open_right_panel_surface(RightPanelSurface::Visuals, cx);
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
        // A folder selects itself and everything beneath it, so a parent like
        // `assets/v3` browses all of its subfolders in one gallery.
        let mut files = self
            .visual_gallery
            .index
            .iter()
            .filter(|(key, _)| visual_folder_contains(&folder, key))
            .flat_map(|(_, files)| files.iter().cloned())
            .collect::<Vec<_>>();
        if files.is_empty() {
            self.visual_gallery.images.clear();
            self.visual_gallery.loading = false;
            self.visual_gallery.list_state.reset(0);
            cx.notify();
            return;
        }
        files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
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
                // that when the set of images actually changed. Render
                // rebuilds the masonry plan and applies the reset.
                if !unchanged {
                    this.visual_gallery.images_epoch =
                        this.visual_gallery.images_epoch.wrapping_add(1);
                    this.visual_gallery.row_plan_key = None;
                    this.visual_gallery.plan_reset_pending = true;
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
        self.visual_gallery.row_plan_key = None;
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
        let target = match key {
            "left" => current.saturating_sub(1),
            "right" => (current + 1).min(count - 1),
            "up" | "down" => {
                let plan = &self.visual_gallery.row_plan;
                let Some(row) = self.visual_row_containing(current) else {
                    return false;
                };
                let adjacent = if key == "up" {
                    row.checked_sub(1)
                } else {
                    (row + 1 < plan.len()).then_some(row + 1)
                };
                match adjacent {
                    Some(adjacent) => {
                        let offset = current - plan[row].start;
                        let row = &plan[adjacent];
                        (row.start + offset).min(row.start + row.widths.len() - 1)
                    }
                    None => current,
                }
            }
            "home" => 0,
            "end" => count - 1,
            _ => return false,
        };
        self.visual_gallery
            .list_state
            .scroll_to_reveal_item(self.visual_row_containing(target).unwrap_or(0));
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
            self.visual_gallery.selected.clear();
            self.schedule_composer_draft_save(cx);
            self.show_success_toast(tr!("visuals.attached", count = attached));
            cx.notify();
        }
    }

    /// Attach one gallery image to the composer, mirroring what attaching a
    /// selection does for each of its images.
    fn attach_visual_gallery_image(&mut self, image: VisualGalleryImage, cx: &mut Context<Self>) {
        let reference = image.reference.clone();
        let name = image.name.clone();
        if !self.stage_daemon_attachment(
            image.stored_path,
            image.name,
            false,
            true,
            reference.clone(),
            None,
        ) {
            return;
        }
        if let Some(attachment) = self
            .composer_attachments
            .iter_mut()
            .find(|attachment| attachment.blob_reference.as_deref() == Some(reference.as_str()))
        {
            attachment.mention = image.relative_path;
        }
        self.schedule_composer_draft_save(cx);
        self.show_success_toast(tr!("visuals.image_attached", name = name));
        cx.notify();
    }

    pub(super) fn render_visuals_surface(
        &mut self,
        panel_width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let theme = Theme::current(cx);
        let folder_menu = self.menu_handle("visuals-folder-menu", cx);
        let layout_menu = self.menu_handle("visuals-layout-menu", cx);
        let folders = visual_folder_choices(self.visual_gallery.index.keys());
        let active_folder = self.visual_gallery.folder.clone();
        let weak = cx.entity().downgrade();
        // The chip shows only the folder's own name: deep paths truncate at
        // the tail, which hides exactly the segment that distinguishes them.
        // The dropdown carries the context as an indented tree instead.
        let folder_trigger = MenuChip::new("visuals-folder-trigger")
            .icon("icons/folder.svg", theme.text_ghost)
            .label(active_folder.clone().map_or_else(
                || tr!("visuals.choose_folder"),
                |folder| visual_folder_display(&folder).1.to_owned(),
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
                        let selected = active_folder.as_deref() == Some(folder.as_str());
                        let (depth, name) = visual_folder_display(folder);
                        let name = SharedString::from(name.to_owned());
                        MenuItem::custom(move |_, cx| {
                            let theme = Theme::current(cx);
                            let color = if selected {
                                theme.text
                            } else {
                                theme.text_secondary
                            };
                            div()
                                .flex_1()
                                .min_w_0()
                                .pl(px(depth as f32 * 14.0))
                                .flex()
                                .items_center()
                                .gap(px(6.0))
                                .child(icon("icons/folder.svg", 12.0, color))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .truncate()
                                        .text_color(color)
                                        .when(selected, |label| {
                                            label.font_weight(FontWeight::MEDIUM)
                                        })
                                        .child(name.clone()),
                                )
                                .when(selected, |row| {
                                    row.child(icon("icons/check.svg", 11.0, theme.text_tertiary))
                                })
                                .into_any_element()
                        })
                        .on_click(move |_, cx| {
                            let _ = weak.update(cx, |this, cx| {
                                this.select_visual_gallery_folder(selected_folder.clone(), cx);
                            });
                        })
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

        // Rebuild the masonry plan when its inputs changed: the image set,
        // newly landed dimensions, the panel width, or the layout mode. The
        // key check keeps this off the ordinary frame path.
        let plan_key = (
            self.visual_gallery.images_epoch,
            self.remote_image_sizes_version.get(),
            (panel_width.max(0.0) * 4.0) as u32,
            layout,
        );
        if self.visual_gallery.row_plan_key != Some(plan_key) {
            let available = (panel_width - waku_protocol::VISUAL_GRID_HORIZONTAL_INSET).max(88.0);
            let sizes = self.remote_image_sizes.borrow();
            self.visual_gallery.row_plan =
                build_visual_row_plan(&self.visual_gallery.images, &sizes, layout, available);
            drop(sizes);
            self.visual_gallery.row_plan_key = Some(plan_key);
            let rows = self.visual_gallery.row_plan.len();
            if self.visual_gallery.plan_reset_pending {
                self.visual_gallery.plan_reset_pending = false;
                self.visual_gallery.list_state.reset(rows);
            } else {
                // A reflow (dimension landed, width or layout changed) keeps
                // the scroll position instead of snapping to the top.
                let old_rows = self.visual_gallery.list_state.item_count();
                self.visual_gallery.list_state.splice(0..old_rows, rows);
            }
        }

        // A pending reveal waits here until its folder's images have landed;
        // this runs at most once per reveal, not per frame.
        if let Some(path) = self.visual_gallery.pending_reveal.clone()
            && !self.visual_gallery.loading
            && let Some(index) = self
                .visual_gallery
                .images
                .iter()
                .position(|image| image.relative_path == path)
        {
            self.visual_gallery.pending_reveal = None;
            self.visual_gallery
                .list_state
                .scroll_to_reveal_item(self.visual_row_containing(index).unwrap_or(0));
            let focus = self.transcript_control_focus(format!("visual-gallery-card-{index}"), cx);
            window.on_next_frame(move |window, cx| window.focus(&focus, cx));
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
                                        this.render_visual_gallery_row(row, window, cx)
                                    })
                                })
                                .unwrap_or_else(|| div().into_any_element())
                        },
                    )
                    .size_full(),
                )
                .into_any_element()
        };

        // The persistent footer is gone; with a selection, a floating pill
        // carries the count and the attach/clear button group.
        let selection_count = self.visual_gallery.selected.len();
        let selection_pill = (selection_count > 0).then(|| {
            let attach_focus = self.transcript_control_focus("visuals-attach-selected", cx);
            let clear_focus = self.transcript_control_focus("visuals-clear-selected", cx);
            div()
                .absolute()
                .bottom(px(14.0))
                .left_0()
                .right_0()
                .flex()
                .justify_center()
                .child(
                    div()
                        .p(px(4.0))
                        .rounded_full()
                        .bg(theme.raised)
                        .border_1()
                        .border_color(theme.border_strong)
                        .shadow_lg()
                        .flex()
                        .items_center()
                        .gap(px(2.0))
                        .child(
                            div()
                                .px(px(10.0))
                                .text_size(sp(11.5))
                                .text_color(theme.text_tertiary)
                                .child(tr!("visuals.selected_count", count = selection_count)),
                        )
                        .child(
                            div()
                                .id("visuals-attach-selected")
                                .track_focus(&attach_focus)
                                .tab_index(0)
                                .h(px(28.0))
                                .px(px(12.0))
                                .rounded_full()
                                .bg(theme.accent)
                                .text_color(gpui::white())
                                .flex()
                                .items_center()
                                .gap(px(5.0))
                                .text_size(sp(11.5))
                                .font_weight(FontWeight::MEDIUM)
                                .focus_visible(|style| style.border_1().border_color(theme.text))
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
                                .child(icon("icons/paperclip.svg", 11.0, gpui::white()))
                                .child(tr!("visuals.attach")),
                        )
                        .child(
                            div()
                                .id("visuals-clear-selected")
                                .track_focus(&clear_focus)
                                .tab_index(0)
                                .h(px(28.0))
                                .px(px(11.0))
                                .rounded_full()
                                .text_color(theme.text_secondary)
                                .flex()
                                .items_center()
                                .text_size(sp(11.5))
                                .font_weight(FontWeight::MEDIUM)
                                .focus_visible(|style| style.border_1().border_color(theme.text))
                                .hover(|style| {
                                    style.bg(theme.overlay_strong).text_color(theme.text)
                                })
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.visual_gallery.selected.clear();
                                    cx.notify();
                                }))
                                .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                        this.visual_gallery.selected.clear();
                                        cx.stop_propagation();
                                        cx.notify();
                                    }
                                }))
                                .child(tr!("visuals.clear")),
                        ),
                )
        });

        div()
            .id("visuals-surface")
            .relative()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .child(toolbar)
            .child(content)
            .when_some(selection_pill, |surface, pill| surface.child(pill))
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
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::current(cx);
        let Some(plan_row) = self.visual_gallery.row_plan.get(row).cloned() else {
            return div().into_any_element();
        };
        let start = plan_row.start;
        let end = (start + plan_row.widths.len()).min(self.visual_gallery.images.len());
        let image_height = plan_row.image_height;
        let mut row_view = div()
            .w_full()
            .px(px(8.0))
            .pt(px(if row == 0 { 8.0 } else { 3.0 }))
            .pb(px(3.0))
            .flex()
            .gap(px(VISUAL_GALLERY_GAP));
        for (index, image) in self.visual_gallery.images[start..end].iter().enumerate() {
            let absolute_index = start + index;
            let card_width = plan_row.widths[index] + VISUAL_CARD_CHROME;
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
            let card_menu =
                self.menu_handle(format!("visual-gallery-context-{absolute_index}"), cx);
            let key_menu = card_menu.clone();
            let menu_weak = cx.entity().downgrade();
            let menu_source = source.clone();
            let menu_name = preview_name.clone();
            let menu_image = image.clone();
            let menu_relative = image.relative_path.clone();
            let menu_absolute = self
                .visual_gallery
                .workspace
                .as_ref()
                .map(|workspace| workspace.join(&image.relative_path));
            let can_reveal = !self.daemon.is_remote() && menu_absolute.is_some();
            // Ring selection: a 2px accent ring offset from the image is the
            // only selected treatment — no fill, no badge. Hover reveals the
            // name scrim and preview button without touching the card chrome,
            // and keyboard focus uses a text-colored ring so it stays
            // distinguishable from the accent selection ring.
            let mut card = div()
                .id(SharedString::from(format!(
                    "visual-gallery-card-{absolute_index}"
                )))
                .track_focus(&focus)
                .tab_index(0)
                .group("visual-gallery-card")
                .relative()
                .overflow_hidden()
                .w(px(card_width))
                .flex_none()
                .p(px(2.0))
                .rounded(px(8.0))
                .border_2()
                .border_color(if selected {
                    theme.accent
                } else {
                    theme.border.opacity(0.0)
                })
                .focus_visible(|style| style.border_color(theme.text));
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
            // The filename scrim and preview button only appear on hover;
            // selection reads from the accent ring alone.
            card = card
                .child(
                    div()
                        .absolute()
                        .bottom(px(2.0))
                        .left(px(2.0))
                        .right(px(2.0))
                        .pt(px(14.0))
                        .px(px(8.0))
                        .pb(px(5.0))
                        .rounded_b(px(5.0))
                        .bg(linear_gradient(
                            180.0,
                            linear_color_stop(gpui::black().opacity(0.0), 0.0),
                            linear_color_stop(gpui::black().opacity(0.62), 1.0),
                        ))
                        .invisible()
                        .group_hover("visual-gallery-card", |strip| strip.visible())
                        .child(
                            div()
                                .min_w_0()
                                .truncate()
                                .text_size(sp(10.5))
                                .text_color(gpui::white().opacity(0.92))
                                .child(image.name.clone()),
                        ),
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
                            .invisible()
                            .group_hover("visual-gallery-card", |style| style.visible())
                            .hover(|style| style.bg(theme.surface))
                            .focus_visible(|style| {
                                style.visible().border_1().border_color(theme.accent)
                            })
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
                    if key == "f10" && event.keystroke.modifiers.shift {
                        key_menu.open_context_menu(window, cx);
                        cx.stop_propagation();
                        return;
                    }
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
            row_view = row_view.child(context_menu(
                card,
                SharedString::from(format!("visual-gallery-context-menu-{absolute_index}")),
                &card_menu,
                move |_| {
                    let mut items = Vec::new();
                    let preview_weak = menu_weak.clone();
                    let preview_source = menu_source.clone();
                    let preview_name = menu_name.clone();
                    items.push(
                        MenuItem::new(tr!("visuals.context_preview"), move |window, cx| {
                            if let Some(source) = preview_source.clone() {
                                let name = preview_name.clone();
                                let _ = preview_weak.update(cx, |this, cx| {
                                    this.open_image_preview(source, name, window, cx);
                                });
                            }
                        })
                        .icon("icons/eye.svg")
                        .disabled(menu_source.is_none()),
                    );
                    let attach_weak = menu_weak.clone();
                    let attach_image = menu_image.clone();
                    items.push(
                        MenuItem::new(tr!("visuals.context_attach"), move |_, cx| {
                            let _ = attach_weak.update(cx, |this, cx| {
                                this.attach_visual_gallery_image(attach_image.clone(), cx);
                            });
                        })
                        .icon("icons/paperclip.svg"),
                    );
                    items.push(MenuItem::Separator);
                    let reveal_path = menu_absolute.clone();
                    items.push(
                        MenuItem::new(tr!("common.reveal_in_finder"), move |_, cx| {
                            if let Some(path) = reveal_path.as_ref() {
                                crate::platform::reveal_in_file_manager(path, cx);
                            }
                        })
                        .icon("icons/folder.svg")
                        .disabled(!can_reveal),
                    );
                    let copy_path = menu_relative.clone();
                    items.push(
                        MenuItem::new(tr!("visuals.copy_path"), move |_, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(copy_path.clone()));
                        })
                        .icon("icons/copy.svg"),
                    );
                    items
                },
            ));
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
    fn parent_folders_select_their_descendants() {
        assert!(visual_folder_contains("assets", "assets"));
        assert!(visual_folder_contains("assets", "assets/hero"));
        assert!(visual_folder_contains("", "assets/hero"));
        assert!(!visual_folder_contains("assets", "assets-old"));
        assert!(!visual_folder_contains("assets/hero", "assets"));

        let keys = ["assets/v3/01".to_owned(), "assets/v3/02".to_owned()];
        assert_eq!(
            visual_folder_choices(keys.iter()),
            ["", "assets", "assets/v3", "assets/v3/01", "assets/v3/02"]
        );

        // Component-wise order keeps a folder's descendants directly beneath
        // it even when a sibling would string-sort between them.
        let keys = ["pages-extra".to_owned(), "pages/hero".to_owned()];
        assert_eq!(
            visual_folder_choices(keys.iter()),
            ["", "pages", "pages/hero", "pages-extra"]
        );
    }

    #[test]
    fn folder_rows_show_depth_and_final_segment() {
        assert_eq!(visual_folder_display(""), (0, "."));
        assert_eq!(visual_folder_display("brand"), (1, "brand"));
        assert_eq!(visual_folder_display("pages/mouth-breathing/v3"), (3, "v3"));
    }

    fn image(reference: &str) -> VisualGalleryImage {
        VisualGalleryImage {
            relative_path: format!("{reference}.png"),
            stored_path: PathBuf::new(),
            name: format!("{reference}.png"),
            reference: reference.to_owned(),
        }
    }

    #[test]
    fn masonry_rows_justify_to_the_available_width() {
        let images = [image("a"), image("b"), image("c"), image("d")];
        let mut sizes = HashMap::new();
        sizes.insert("a".to_owned(), (1600, 800)); // 2.0
        sizes.insert("b".to_owned(), (800, 800)); // 1.0
        sizes.insert("c".to_owned(), (600, 1200)); // 0.5
        sizes.insert("d".to_owned(), (900, 900)); // 1.0
        let plan = build_visual_row_plan(&images, &sizes, VisualGalleryLayout::Compact, 420.0);
        // Every full row's widths plus chrome and gaps must equal the width.
        for row in &plan[..plan.len() - 1] {
            let count = row.widths.len() as f32;
            let total = row.widths.iter().sum::<f32>()
                + count * VISUAL_CARD_CHROME
                + (count - 1.0) * VISUAL_GALLERY_GAP;
            assert!((total - 420.0).abs() < 0.5, "row fills width, got {total}");
        }
        // The final row keeps the target height rather than stretching.
        let last = plan.last().unwrap();
        assert!(last.image_height <= VISUAL_MASONRY_COMPACT_ROW + 0.5);
        // Rows tile the image list without gaps or overlap.
        let mut next = 0;
        for row in &plan {
            assert_eq!(row.start, next);
            next += row.widths.len();
        }
        assert_eq!(next, images.len());
    }

    #[test]
    fn fit_layout_gives_every_image_its_own_aspect_row() {
        let images = [image("wide"), image("tall")];
        let mut sizes = HashMap::new();
        sizes.insert("wide".to_owned(), (2000, 1000));
        sizes.insert("tall".to_owned(), (500, 1000));
        let plan = build_visual_row_plan(&images, &sizes, VisualGalleryLayout::Fit, 408.0);
        assert_eq!(plan.len(), 2);
        assert!(plan[0].image_height < plan[1].image_height);
        assert_eq!(plan[0].widths.len(), 1);
    }

    #[test]
    fn image_dimensions_probe_reads_common_headers() {
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        png.extend([0, 0, 0, 13]);
        png.extend(*b"IHDR");
        png.extend(640u32.to_be_bytes());
        png.extend(480u32.to_be_bytes());
        assert_eq!(probe_image_dimensions(&png), Some((640, 480)));

        let mut gif = b"GIF89a".to_vec();
        gif.extend(320u16.to_le_bytes());
        gif.extend(200u16.to_le_bytes());
        assert_eq!(probe_image_dimensions(&gif), Some((320, 200)));

        // JPEG: APP0 segment then SOF0 with height 480, width 640.
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00];
        jpeg.extend([0xFF, 0xC0, 0x00, 0x11, 0x08]);
        jpeg.extend(480u16.to_be_bytes());
        jpeg.extend(640u16.to_be_bytes());
        jpeg.extend([0x03]);
        assert_eq!(probe_image_dimensions(&jpeg), Some((640, 480)));

        assert_eq!(probe_image_dimensions(b"<svg xmlns='...'/>"), None);
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

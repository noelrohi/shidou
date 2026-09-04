//! Background Mermaid rendering and the bounded process-wide SVG cache.
//!
//! Transcript frames only claim work and read ready images. Parsing, layout,
//! font discovery, and SVG serialization all run on GPUI's background
//! executor. Cache entries also remember every pane waiting on an in-flight
//! render, so one source/theme pair is rendered once and completion notifies
//! only the panes that asked for it.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use gpui::{App, EntityId, Global, Image, ImageFormat};
use mermaid_rs_renderer::{RenderOptions, Theme as MermaidTheme, render_strict};

const MAX_SOURCE_BYTES: usize = 128 * 1024;
const MAX_SVG_BYTES: usize = 2 * 1024 * 1024;
const MAX_CACHE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Appearance {
    Light,
    Dark,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct Key {
    source: Arc<str>,
    appearance: Appearance,
}

impl Key {
    pub fn new(source: Arc<str>, appearance: Appearance) -> Self {
        Self { source, appearance }
    }

    #[cfg(test)]
    fn from_source(source: &str, appearance: Appearance) -> Self {
        Self::new(Arc::from(source), appearance)
    }
}

pub enum Status {
    Ready(Arc<Image>),
    Pending,
    Unavailable,
}

enum Entry {
    Pending {
        waiters: HashSet<EntityId>,
    },
    Ready {
        image: Arc<Image>,
        bytes: usize,
        last_used: u64,
    },
    Unavailable {
        bytes: usize,
        last_used: u64,
    },
}

#[derive(Default)]
struct Cache {
    entries: HashMap<Key, Entry>,
    bytes: usize,
    clock: u64,
}

impl Global for Cache {}

impl Cache {
    fn lookup(&mut self, key: &Key, target: EntityId) -> Lookup {
        self.clock = self.clock.wrapping_add(1);
        let now = self.clock;
        match self.entries.get_mut(key) {
            Some(Entry::Pending { waiters }) => {
                waiters.insert(target);
                Lookup::Pending
            }
            Some(Entry::Ready {
                image, last_used, ..
            }) => {
                *last_used = now;
                Lookup::Ready(image.clone())
            }
            Some(Entry::Unavailable { last_used, .. }) => {
                *last_used = now;
                Lookup::Unavailable
            }
            None => {
                self.entries.insert(
                    key.clone(),
                    Entry::Pending {
                        waiters: HashSet::from([target]),
                    },
                );
                Lookup::Start
            }
        }
    }

    fn finish(&mut self, key: &Key, svg: Option<Vec<u8>>) -> Vec<EntityId> {
        let Some(Entry::Pending { waiters }) = self.entries.remove(key) else {
            return Vec::new();
        };
        self.clock = self.clock.wrapping_add(1);
        let last_used = self.clock;
        let key_bytes = key.source.len();
        let entry = match svg {
            Some(svg) => {
                let bytes = key_bytes + svg.len();
                self.bytes += bytes;
                Entry::Ready {
                    image: Arc::new(Image::from_bytes(ImageFormat::Svg, svg)),
                    bytes,
                    last_used,
                }
            }
            None => {
                self.bytes += key_bytes;
                Entry::Unavailable {
                    bytes: key_bytes,
                    last_used,
                }
            }
        };
        self.entries.insert(key.clone(), entry);
        self.evict_over_budget();
        waiters.into_iter().collect()
    }

    fn evict_over_budget(&mut self) {
        while self.bytes > MAX_CACHE_BYTES {
            let victim = self
                .entries
                .iter()
                .filter_map(|(key, entry)| match entry {
                    Entry::Ready {
                        bytes, last_used, ..
                    }
                    | Entry::Unavailable { bytes, last_used } => {
                        Some((key.clone(), *bytes, *last_used))
                    }
                    Entry::Pending { .. } => None,
                })
                .min_by_key(|(_, _, last_used)| *last_used);
            let Some((key, bytes, _)) = victim else {
                break;
            };
            self.entries.remove(&key);
            self.bytes = self.bytes.saturating_sub(bytes);
        }
    }
}

enum Lookup {
    Ready(Arc<Image>),
    Pending,
    Unavailable,
    Start,
}

/// Read or claim one diagram. A miss starts exactly one background render.
pub fn request(key: &Key, target: EntityId, cx: &mut App) -> Status {
    if key.source.is_empty() || key.source.len() > MAX_SOURCE_BYTES {
        return Status::Unavailable;
    }

    let lookup = cx.default_global::<Cache>().lookup(key, target);
    match lookup {
        Lookup::Ready(image) => Status::Ready(image),
        Lookup::Pending => Status::Pending,
        Lookup::Unavailable => Status::Unavailable,
        Lookup::Start => {
            let key = key.clone();
            let source = key.source.to_string();
            let appearance = key.appearance;
            cx.spawn(async move |cx| {
                let svg = cx
                    .background_executor()
                    .spawn(async move { render_svg_source(&source, appearance) })
                    .await;
                cx.update(|cx| {
                    let waiters = cx.default_global::<Cache>().finish(&key, svg);
                    for waiter in waiters {
                        cx.notify(waiter);
                    }
                });
            })
            .detach();
            Status::Pending
        }
    }
}

fn render_svg_source(source: &str, appearance: Appearance) -> Option<Vec<u8>> {
    let mut theme = match appearance {
        Appearance::Light => MermaidTheme::modern(),
        Appearance::Dark => MermaidTheme::dark(),
    };
    // The renderer paints this across the full viewBox before diagram content.
    theme.background = "none".to_string();
    let svg = render_strict(
        source,
        RenderOptions {
            theme,
            ..RenderOptions::default()
        },
    )
    .ok()?;
    (svg.len() <= MAX_SVG_BYTES).then(|| svg.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_valid_source_for_both_appearances() {
        for appearance in [Appearance::Light, Appearance::Dark] {
            let svg = render_svg_source("flowchart LR\nA[Start] --> B[Done]", appearance)
                .expect("supported Mermaid should render");
            let svg = String::from_utf8(svg).unwrap();
            assert!(svg.contains("<svg"));
            assert!(svg.contains("Start"));
            assert!(svg.contains("Done"));
            let root_background = svg
                .split_once("<rect")
                .and_then(|(_, rest)| rest.split_once("/>"))
                .map(|(attributes, _)| attributes)
                .expect("renderer should emit its root background rectangle");
            assert!(
                root_background.contains("fill=\"none\""),
                "diagram canvas should be transparent: {root_background}"
            );
        }
    }

    #[test]
    fn malformed_or_unsupported_source_has_no_image() {
        assert!(render_svg_source("notADiagram\nA --> B", Appearance::Light).is_none());
    }

    #[test]
    fn cache_deduplicates_pending_work_and_keeps_all_waiters() {
        let mut cache = Cache::default();
        let key = Key::from_source("flowchart LR; A-->B", Appearance::Light);
        assert!(matches!(cache.lookup(&key, 1_u64.into()), Lookup::Start));
        assert!(matches!(cache.lookup(&key, 2_u64.into()), Lookup::Pending));

        let waiters = cache.finish(&key, None);
        assert_eq!(waiters.len(), 2);
        assert!(waiters.contains(&1_u64.into()));
        assert!(waiters.contains(&2_u64.into()));
        assert!(matches!(
            cache.lookup(&key, 3_u64.into()),
            Lookup::Unavailable
        ));
    }

    #[test]
    fn resolved_entries_are_evicted_to_the_byte_budget() {
        let mut cache = Cache::default();
        for index in 0..100 {
            let source = format!("{index}:{}", "x".repeat(100 * 1024));
            let key = Key::from_source(&source, Appearance::Light);
            assert!(matches!(
                cache.lookup(&key, (index as u64 + 1).into()),
                Lookup::Start
            ));
            cache.finish(&key, None);
        }
        assert!(cache.bytes <= MAX_CACHE_BYTES);
        assert!(cache.entries.len() < 100);
    }

    #[test]
    fn source_and_appearance_both_participate_in_the_key() {
        let source = Key::from_source("flowchart LR; A-->B", Appearance::Light);
        let changed = Key::from_source("flowchart LR; A-->C", Appearance::Light);
        let dark = Key::from_source("flowchart LR; A-->B", Appearance::Dark);
        assert_ne!(source, changed);
        assert_ne!(source, dark);
    }
}

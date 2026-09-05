//! The diff shown inside an expanded file-change activity.
//!
//! There is nothing to parse here: provider payloads are normalized into
//! unified-diff bodies when the tool event arrives, and
//! [`review_diff::from_file_changes`] turns those into the same positioned,
//! syntax-tokenized rows the Review panel reads. The transcript retains the
//! capped provider snapshot and renders only the rows visible in its scroll viewport.

use crate::model::ActivityItem;
use crate::review_diff::{self, LineKind, Snapshot};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

/// Each expansion gets a new token. A retired job cannot replace a newer
/// snapshot or remove the newer expansion's pending flag.
#[derive(Default)]
pub(super) struct Jobs(HashMap<Uuid, Uuid>);

impl Jobs {
    pub(super) fn begin(&mut self, activity_id: Uuid) -> Option<Uuid> {
        if self.0.contains_key(&activity_id) {
            return None;
        }
        let token = Uuid::new_v4();
        self.0.insert(activity_id, token);
        Some(token)
    }

    pub(super) fn finish(&mut self, activity_id: Uuid, token: Uuid) -> bool {
        if self.0.get(&activity_id) != Some(&token) {
            return false;
        }
        self.0.remove(&activity_id);
        true
    }

    pub(super) fn invalidate(&mut self, activity_id: Uuid) {
        self.0.remove(&activity_id);
    }

    pub(super) fn clear(&mut self) {
        self.0.clear();
    }
}

/// Stop at the viewport boundary; measuring a frame never walks the whole patch.
pub(super) fn viewport_height<'a>(
    lines: impl Iterator<Item = &'a review_diff::Line>,
    code_line_height: f32,
    max_height: f32,
) -> f32 {
    let mut height = 0.0;
    for line in lines {
        height += match line.kind {
            LineKind::FileHeader => 24.0,
            LineKind::Context | LineKind::Addition | LineKind::Deletion => code_line_height,
            _ => 20.0,
        };
        if height >= max_height {
            break;
        }
    }
    height.min(max_height)
}

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Diff {
    pub(super) snapshot: Snapshot,
    pub(super) recorded_stats: HashMap<String, (Option<u64>, Option<u64>)>,
    pub(super) row_notes: HashMap<usize, Note>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Note {
    MissingDiff,
    DisplayLimit,
}

impl Diff {
    pub(super) fn is_empty(&self) -> bool {
        self.snapshot.lines.is_empty()
    }

    /// Whether any row knows where it sits in its file. Providers that only
    /// report before/after text leave every row unpositioned, and the gutter
    /// falls back to the `+`/`-` marker.
    #[cfg(test)]
    fn has_line_numbers(&self) -> bool {
        self.snapshot
            .lines
            .iter()
            .any(|line| line.old_line.is_some() || line.new_line.is_some())
    }
}

/// Build the rows for one activity's file changes.
///
/// Runs on the background executor when an activity is expanded. The caller
/// virtualizes the snapshot until the changes are replaced. The shared safety
/// cap remains in force and the UI discloses truncation.
pub(super) fn build(activity: &ActivityItem) -> Diff {
    let mut snapshot = review_diff::from_file_changes(&activity.file_changes);
    let mut recorded_stats = HashMap::new();
    let mut missing = HashSet::new();
    for change in &activity.file_changes {
        let counts = recorded_stats
            .entry(change.path.clone())
            .or_insert((Some(0u64), Some(0u64)));
        counts.0 = counts
            .0
            .and_then(|sum| change.additions.and_then(|count| sum.checked_add(count)));
        counts.1 = counts
            .1
            .and_then(|sum| change.deletions.and_then(|count| sum.checked_add(count)));
        if change
            .diff
            .as_deref()
            .is_none_or(|body| body.trim().is_empty())
        {
            missing.insert(change.path.as_str());
        }
    }
    // Keep a summary for every file, including files beyond the shared row cap.
    for (file_index, file) in snapshot.files.iter().enumerate() {
        if file.diff_line.is_none() {
            snapshot.lines.push(review_diff::Line {
                file_index,
                old_line: None,
                new_line: None,
                kind: LineKind::FileHeader,
                content: String::new(),
                tokens: Vec::new(),
            });
        }
    }
    let mut lines = Vec::new();
    let mut row_notes = HashMap::new();
    for line in std::mem::take(&mut snapshot.lines) {
        let is_header = line.kind == LineKind::FileHeader;
        let file_index = line.file_index;
        // One file needs no header: the activity's own row already names it.
        if !is_header || snapshot.files.len() > 1 {
            lines.push(line);
        }
        if is_header {
            let file = &snapshot.files[file_index];
            let note = if missing.contains(file.path.as_str()) {
                Some(Note::MissingDiff)
            } else if file.diff_line.is_none() {
                Some(Note::DisplayLimit)
            } else {
                None
            };
            if let Some(note) = note {
                row_notes.insert(lines.len(), note);
                lines.push(review_diff::Line {
                    file_index,
                    old_line: None,
                    new_line: None,
                    kind: LineKind::Meta,
                    content: String::new(),
                    tokens: Vec::new(),
                });
            }
        }
    }
    snapshot.lines = lines;
    Diff {
        snapshot,
        recorded_stats,
        row_notes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ActivityFileChange, ActivityKind};

    fn activity(changes: Vec<ActivityFileChange>) -> ActivityItem {
        let mut activity = ActivityItem::new(None, ActivityKind::FileChange, "Edit", None, true);
        activity.file_changes = changes;
        activity
    }

    fn change(path: &str, diff: &str) -> ActivityFileChange {
        ActivityFileChange {
            path: path.into(),
            additions: Some(1),
            deletions: Some(1),
            status: None,
            diff: Some(diff.into()),
        }
    }

    #[test]
    fn replacement_rejects_the_old_job_without_retiring_the_new_one() {
        let id = Uuid::new_v4();
        let mut jobs = Jobs::default();
        let old = jobs.begin(id).unwrap();
        assert_eq!(jobs.begin(id), None);
        jobs.invalidate(id);
        let new = jobs.begin(id).unwrap();
        assert!(!jobs.finish(id, old));
        assert_eq!(
            jobs.begin(id),
            None,
            "stale completion must not retire the replacement"
        );
        assert!(jobs.finish(id, new));
        assert!(!jobs.finish(id, new), "each result is accepted once");
        assert!(
            jobs.begin(id).is_some(),
            "completion retires the pending flag"
        );
    }

    #[test]
    fn collapse_retires_pending_work_and_reopening_can_build_again() {
        let id = Uuid::new_v4();
        let mut jobs = Jobs::default();
        let old = jobs.begin(id).unwrap();
        jobs.invalidate(id);
        assert!(!jobs.finish(id, old));
        let reopened = jobs.begin(id).unwrap();
        assert!(jobs.finish(id, reopened));
    }

    #[test]
    fn session_reset_rejects_all_old_jobs_even_after_reopening() {
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let mut jobs = Jobs::default();
        let old_first = jobs.begin(first).unwrap();
        let old_second = jobs.begin(second).unwrap();
        jobs.clear();
        let new = jobs.begin(first).unwrap();
        assert!(!jobs.finish(first, old_first));
        assert!(!jobs.finish(second, old_second));
        assert_eq!(jobs.begin(first), None);
        assert!(jobs.finish(first, new));
        assert!(jobs.begin(second).is_some());
    }

    #[test]
    fn viewport_measurement_stops_at_the_visible_height() {
        let diff = build(&activity(vec![change("one.txt", "@@\n+one\n")]));
        let line = diff.snapshot.lines.last().unwrap();
        let inspected = std::cell::Cell::new(0);
        let lines =
            std::iter::repeat_n(line, 50_000).inspect(|_| inspected.set(inspected.get() + 1));
        assert_eq!(viewport_height(lines, 20.0, 400.0), 400.0);
        assert_eq!(
            inspected.get(),
            20,
            "measurement must not scan all retained rows"
        );
        assert_eq!(viewport_height(std::iter::once(line), 20.0, 400.0), 20.0);
        let rows = gpui::ListState::new(50_000, gpui::ListAlignment::Top, gpui::px(200.0));
        assert_eq!(
            rows.item_count(),
            50_000,
            "the virtual list retains every displayable row"
        );
    }

    #[test]
    fn positioned_hunks_number_both_sides() {
        let diff = build(&activity(vec![change(
            "src/lib.rs",
            "@@ -10,3 +10,3 @@\n let kept = 1;\n-let old = 2;\n+let new = 2;\n",
        )]));

        let code = diff
            .snapshot
            .lines
            .iter()
            .filter(|line| {
                matches!(
                    line.kind,
                    LineKind::Context | LineKind::Addition | LineKind::Deletion
                )
            })
            .map(|line| (line.kind.clone(), line.old_line, line.new_line))
            .collect::<Vec<_>>();
        assert_eq!(
            code,
            vec![
                (LineKind::Context, Some(10), Some(10)),
                (LineKind::Deletion, Some(11), None),
                (LineKind::Addition, None, Some(11)),
            ]
        );
        assert!(diff.has_line_numbers());
        let context = diff
            .snapshot
            .lines
            .iter()
            .find(|line| line.kind == LineKind::Context)
            .expect("context row");
        assert_eq!(context.content, "let kept = 1;");
        assert!(!context.tokens.is_empty(), "Rust rows are highlighted");
    }

    #[test]
    fn positionless_hunks_render_without_inventing_line_numbers() {
        let diff = build(&activity(vec![change(
            "src/lib.rs",
            "@@\n-let old = 2;\n+let new = 2;\n",
        )]));

        assert!(!diff.has_line_numbers());
        assert!(
            diff.snapshot
                .lines
                .iter()
                .all(|line| line.old_line.is_none() && line.new_line.is_none())
        );
    }

    #[test]
    fn several_files_are_labeled_and_a_single_file_is_not() {
        let one = build(&activity(vec![change("src/one.rs", "@@\n+one\n")]));
        assert!(
            one.snapshot
                .lines
                .iter()
                .all(|line| line.kind != LineKind::FileHeader)
        );

        let two = build(&activity(vec![
            change("src/one.rs", "@@\n+one\n"),
            change("src/two.rs", "@@\n+two\n"),
        ]));
        let files = two
            .snapshot
            .lines
            .iter()
            .filter(|line| line.kind == LineKind::FileHeader)
            .filter_map(|line| two.snapshot.files.get(line.file_index))
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>();
        assert_eq!(files, vec!["src/one.rs", "src/two.rs"]);
    }

    #[test]
    fn multi_file_headers_preserve_unknown_counts_independently() {
        let mut first = change("one.txt", "@@\n+one\n");
        first.additions = None;
        first.deletions = Some(0);
        let mut second = change("two.txt", "@@\n-two\n");
        second.additions = Some(0);
        second.deletions = None;
        let diff = build(&activity(vec![first, second]));
        let headers = diff
            .snapshot
            .lines
            .iter()
            .filter(|line| line.kind == LineKind::FileHeader)
            .map(|line| {
                let file = &diff.snapshot.files[line.file_index];
                (
                    super::super::transcript::recorded_edit_stat(
                        diff.recorded_stats[&file.path].0,
                        '+',
                    ),
                    super::super::transcript::recorded_edit_stat(
                        diff.recorded_stats[&file.path].1,
                        '-',
                    ),
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            headers,
            vec![("+?".into(), "-0".into()), ("+0".into(), "-?".into())]
        );
    }

    #[test]
    fn mixed_and_missing_only_activities_name_each_missing_diff() {
        let known = change("known.txt", "@@\n+known\n");
        let mut missing = change("missing.txt", "");
        missing.diff = None;
        let blank = change("blank.txt", "  \n");
        let diff = build(&activity(vec![known, missing.clone(), blank]));
        let missing_paths = diff
            .row_notes
            .iter()
            .filter_map(|(index, note)| {
                (*note == Note::MissingDiff).then(|| {
                    diff.snapshot.files[diff.snapshot.lines[*index].file_index]
                        .path
                        .as_str()
                })
            })
            .collect::<HashSet<_>>();
        assert_eq!(missing_paths, HashSet::from(["missing.txt", "blank.txt"]));
        let single = activity(vec![missing]);
        assert!(super::super::components::activity_shows_diff(&single));
        let diff = build(&single);
        assert!(!diff.is_empty());
        assert_eq!(diff.row_notes.get(&0), Some(&Note::MissingDiff));
    }

    #[test]
    fn review_keeps_rows_and_later_files_beyond_the_old_400_row_cap() {
        let body = (0..420)
            .map(|line| format!("+line {line}\n"))
            .collect::<String>();
        let diff = build(&activity(vec![
            change("first.txt", &body),
            change("last.txt", "@@\n+last\n"),
        ]));
        assert!(diff.snapshot.lines.len() > 420);
        assert_eq!(diff.snapshot.lines.last().unwrap().content, "last");
        assert!(!diff.snapshot.truncated);
    }

    #[test]
    fn review_discloses_the_shared_safety_cap_and_keeps_late_file_summaries() {
        let body = std::iter::once("@@\n".to_owned())
            .chain((0..50_020).map(|line| format!("+line {line}\n")))
            .collect::<String>();

        let mut last = change("last.txt", "@@\n+last edit\n");
        last.additions = None;
        last.deletions = Some(0);
        let diff = build(&activity(vec![change("first.txt", &body), last]));

        assert!(diff.snapshot.truncated);
        assert!(diff.snapshot.lines.len() <= 50_002);
        assert_eq!(diff.recorded_stats["last.txt"], (None, Some(0)));
        assert!(
            diff.row_notes
                .values()
                .any(|note| *note == Note::DisplayLimit)
        );
        assert_eq!(diff.snapshot.lines.last().unwrap().file_index, 1);
    }
}

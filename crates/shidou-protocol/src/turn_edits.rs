//! Provider-recorded edits for one turn, independent of Git workspace checkpoints.
//!
//! Counts sum the reported edit operations, not a net before/after diff. A
//! missing count stays unknown, including in the file and turn totals.

use std::collections::HashMap;

use uuid::Uuid;

use crate::model::{ActivityItem, ActivityKind, AgentSession, AgentTurn};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecordedTurnEdits {
    pub files: Vec<RecordedFileEdit>,
    pub additions: Option<u64>,
    pub deletions: Option<u64>,
    /// Transcript order, for opening the original provider diffs for review.
    pub activity_ids: Vec<Uuid>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordedFileEdit {
    pub path: String,
    pub additions: Option<u64>,
    pub deletions: Option<u64>,
}

/// Build once when the transcript changes, not on every rendered frame.
/// Only explicitly attributed, completed, successful file edits qualify.
/// Shell commands and workspace snapshots are never attribution fallbacks.
pub fn recorded_turn_edits(session: &AgentSession, turn: &AgentTurn) -> RecordedTurnEdits {
    let mut edits = EditAccumulator::default();
    for activity in session
        .transcript_blocks
        .iter()
        .filter(|block| block.turn_id == Some(turn.id))
        .flat_map(|block| &block.activities)
    {
        edits.add(activity);
    }
    edits.finish()
}

/// Collect every turn in one transcript pass, rather than scanning the entire
/// task separately for each response card. Clients cache this by edit revision.
pub fn recorded_edits_by_turn(session: &AgentSession) -> HashMap<Uuid, RecordedTurnEdits> {
    let mut turns = HashMap::<Uuid, EditAccumulator<'_>>::new();
    for block in &session.transcript_blocks {
        let Some(turn_id) = block.turn_id else {
            continue;
        };
        for activity in &block.activities {
            if is_recorded_edit(activity) {
                turns.entry(turn_id).or_default().add(activity);
            }
        }
    }
    turns
        .into_iter()
        .map(|(id, edits)| (id, edits.finish()))
        .collect()
}

fn is_recorded_edit(activity: &ActivityItem) -> bool {
    activity.kind == ActivityKind::FileChange
        && activity.complete
        && !activity.failed
        && activity
            .file_changes
            .iter()
            .any(|change| !change.path.trim().is_empty())
}

#[derive(Default)]
struct EditAccumulator<'a> {
    result: RecordedTurnEdits,
    file_indices: HashMap<&'a str, usize>,
}

impl<'a> EditAccumulator<'a> {
    fn add(&mut self, activity: &'a ActivityItem) {
        if !is_recorded_edit(activity) {
            return;
        }
        for change in &activity.file_changes {
            if change.path.trim().is_empty() {
                continue;
            }
            if let Some(&index) = self.file_indices.get(change.path.as_str()) {
                let file = &mut self.result.files[index];
                file.additions = add_counts(file.additions, change.additions);
                file.deletions = add_counts(file.deletions, change.deletions);
            } else {
                self.file_indices
                    .insert(&change.path, self.result.files.len());
                self.result.files.push(RecordedFileEdit {
                    path: change.path.clone(),
                    additions: change.additions,
                    deletions: change.deletions,
                });
            }
        }
        self.result.activity_ids.push(activity.id);
    }

    fn finish(mut self) -> RecordedTurnEdits {
        self.result.additions = self
            .result
            .files
            .iter()
            .try_fold(0_u64, |sum, file| sum.checked_add(file.additions?));
        self.result.deletions = self
            .result
            .files
            .iter()
            .try_fold(0_u64, |sum, file| sum.checked_add(file.deletions?));
        self.result
    }
}

fn add_counts(left: Option<u64>, right: Option<u64>) -> Option<u64> {
    left?.checked_add(right?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        ActivityFileChange, ActivityItem, Checkpoint, CheckpointFile, CheckpointStatus,
        ProviderKind, TranscriptBlock,
    };

    fn edit(path: &str, additions: Option<u64>, deletions: Option<u64>) -> ActivityItem {
        let mut activity = ActivityItem::new(None, ActivityKind::FileChange, "Edit", None, true);
        activity.file_changes.push(ActivityFileChange {
            path: path.to_owned(),
            additions,
            deletions,
            status: None,
            diff: None,
        });
        activity
    }

    fn session_with_edits(activities: Vec<ActivityItem>) -> AgentSession {
        let mut session = AgentSession::new(Uuid::new_v4(), ProviderKind::Pi);
        let turn_id = session.begin_turn("edit one file");
        session.transcript_blocks.push(TranscriptBlock {
            after_message: 0,
            turn_id: Some(turn_id),
            activities,
        });
        session
    }

    #[test]
    fn workspace_checkpoint_is_never_an_attribution_fallback() {
        let mut session = session_with_edits(vec![]);
        session.turns[0].checkpoint = Some(Checkpoint {
            turn_count: 1,
            git_ref: String::new(),
            status: CheckpointStatus::Ready,
            files: vec![CheckpointFile {
                path: "another-task.txt".into(),
                additions: 99,
                deletions: 42,
            }],
            additions: 99,
            deletions: 42,
            created_at: 0,
        });
        let edits = recorded_turn_edits(&session, &session.turns[0]);
        assert!(edits.files.is_empty());
        assert!(edits.activity_ids.is_empty());
    }

    #[test]
    fn same_file_workspace_changes_do_not_supply_recorded_edit_counts() {
        let mut session = session_with_edits(vec![edit("shared.txt", Some(2), Some(1))]);
        session.turns[0].checkpoint = Some(Checkpoint {
            turn_count: 1,
            git_ref: String::new(),
            status: CheckpointStatus::Ready,
            files: vec![CheckpointFile {
                path: "shared.txt".into(),
                additions: 999,
                deletions: 888,
            }],
            additions: 999,
            deletions: 888,
            created_at: 0,
        });
        let edits = recorded_turn_edits(&session, &session.turns[0]);
        assert_eq!(edits.additions, Some(2));
        assert_eq!(edits.deletions, Some(1));
        assert_eq!(edits.files[0].additions, Some(2));
    }

    #[test]
    fn only_successful_completed_edits_in_this_turn_are_included() {
        let accepted = edit("ours.txt", Some(2), Some(1));
        let mut failed = edit("failed.txt", Some(10), Some(0));
        failed.failed = true;
        let mut incomplete = edit("pending.txt", Some(10), Some(0));
        incomplete.complete = false;
        let mut command = edit("shell.txt", Some(10), Some(0));
        command.kind = ActivityKind::Command;
        let mut session = session_with_edits(vec![
            failed,
            incomplete,
            command,
            edit("  ", Some(1), Some(0)),
            accepted.clone(),
        ]);
        for turn_id in [Some(Uuid::new_v4()), None] {
            session.transcript_blocks.push(TranscriptBlock {
                after_message: 0,
                turn_id,
                activities: vec![edit("unattributed.txt", Some(10), Some(0))],
            });
        }
        let edits = recorded_turn_edits(&session, &session.turns[0]);
        assert_eq!(
            edits.files,
            vec![RecordedFileEdit {
                path: "ours.txt".into(),
                additions: Some(2),
                deletions: Some(1),
            }]
        );
        assert_eq!(edits.activity_ids, vec![accepted.id]);
        assert_eq!(edits.additions, Some(2));
        assert_eq!(edits.deletions, Some(1));
    }

    #[test]
    fn repeated_edits_sum_operations_in_first_seen_path_order() {
        let first = edit("b.txt", Some(2), Some(1));
        let second = edit("a.txt", Some(3), Some(0));
        let third = edit("b.txt", Some(1), Some(2));
        let session = session_with_edits(vec![first.clone(), second.clone(), third.clone()]);
        let edits = recorded_turn_edits(&session, &session.turns[0]);
        assert_eq!(
            edits.files,
            vec![
                RecordedFileEdit {
                    path: "b.txt".into(),
                    additions: Some(3),
                    deletions: Some(3)
                },
                RecordedFileEdit {
                    path: "a.txt".into(),
                    additions: Some(3),
                    deletions: Some(0)
                },
            ]
        );
        assert_eq!(edits.activity_ids, vec![first.id, second.id, third.id]);
        assert_eq!(edits.additions, Some(6));
        assert_eq!(edits.deletions, Some(3));
    }

    #[test]
    fn unknown_counts_stay_unknown_per_side_and_in_totals() {
        let session = session_with_edits(vec![
            edit("a.txt", Some(3), Some(2)),
            edit("a.txt", None, Some(1)),
            edit("b.txt", Some(4), None),
        ]);
        let edits = recorded_turn_edits(&session, &session.turns[0]);
        assert_eq!(edits.files[0].additions, None);
        assert_eq!(edits.files[0].deletions, Some(3));
        assert_eq!(edits.files[1].additions, Some(4));
        assert_eq!(edits.files[1].deletions, None);
        assert_eq!(edits.additions, None);
        assert_eq!(edits.deletions, None);
    }

    #[test]
    fn all_turns_are_collected_without_mixing_their_edits() {
        let mut session = session_with_edits(vec![edit("a.txt", Some(1), Some(0))]);
        let first_turn = session.turns[0].clone();
        let second_id = session.begin_turn("second prompt");
        session.transcript_blocks.push(TranscriptBlock {
            after_message: 1,
            turn_id: Some(second_id),
            activities: vec![edit("a.txt", Some(10), Some(2))],
        });
        let second_turn = session.turns.last().unwrap();
        let all = recorded_edits_by_turn(&session);
        assert_eq!(all.len(), 2);
        assert_eq!(
            all[&first_turn.id],
            recorded_turn_edits(&session, &first_turn)
        );
        assert_eq!(all[&second_id], recorded_turn_edits(&session, second_turn));
        assert_eq!(all[&first_turn.id].additions, Some(1));
        assert_eq!(all[&second_id].additions, Some(10));
    }

    #[test]
    fn overflowing_counts_are_unknown_not_wrapped() {
        let session = session_with_edits(vec![
            edit("a.txt", Some(u64::MAX), Some(0)),
            edit("a.txt", Some(1), Some(0)),
        ]);
        let edits = recorded_turn_edits(&session, &session.turns[0]);
        assert_eq!(edits.files[0].additions, None);
        assert_eq!(edits.additions, None);
    }
}

import type { ActivityItem, AgentSession } from '@shidou/client'

export type RecordedEditFile = {
  path: string
  additions: number | null
  deletions: number | null
}

export type RecordedEdits = {
  files: RecordedEditFile[]
  additions: number | null
  deletions: number | null
  activities: ActivityItem[]
}

export function isRecordedEdit(activity: ActivityItem): boolean {
  return activity.kind === 'fileChange' && activity.complete && !activity.failed
    && Boolean(activity.file_changes?.some((change) => change.path.trim().length > 0))
}

function addKnown(a: number | null, b: number | null | undefined): number | null {
  if (a == null || b == null) return null
  const sum = a + b
  return Number.isSafeInteger(sum) ? sum : null
}

type Transcript = Pick<AgentSession, 'transcript_blocks'>
type EditRevision = { summary?: ReadonlyMap<string, RecordedEdits> }

// Revisions are client-only and shared across reducer clones until an edit or
// its turn attribution changes. Text streaming must not rescan historical edits.
// A fresh snapshot gets its own revision; weak keys allow old snapshots to expire.
const revisions = new WeakMap<AgentSession['transcript_blocks'], EditRevision>()

function editRevision(session: Transcript): EditRevision {
  let revision = revisions.get(session.transcript_blocks)
  if (!revision) {
    revision = {}
    revisions.set(session.transcript_blocks, revision)
  }
  return revision
}

export function inheritRecordedEditsRevision(current: Transcript, next: Transcript): void {
  revisions.set(next.transcript_blocks, editRevision(current))
}

export function invalidateRecordedEdits(session: Transcript): void {
  revisions.delete(session.transcript_blocks)
}

export function recordedEditsByTurn(session: Transcript): ReadonlyMap<string, RecordedEdits> {
  const revision = editRevision(session)
  if (revision.summary) return revision.summary
  const turns = new Map<string, RecordedEdits>()
  const pathsByTurn = new Map<string, Map<string, RecordedEditFile>>()
  for (const block of session.transcript_blocks) {
    if (!block.turn_id || block.content.kind !== 'activities') continue
    for (const activity of block.content.data) {
      if (!isRecordedEdit(activity)) continue
      let edits = turns.get(block.turn_id)
      if (!edits) {
        edits = { files: [], additions: 0, deletions: 0, activities: [] }
        turns.set(block.turn_id, edits)
        pathsByTurn.set(block.turn_id, new Map())
      }
      edits.activities.push(activity)
      const paths = pathsByTurn.get(block.turn_id)!
      for (const change of activity.file_changes!) {
        if (!change.path.trim()) continue
        let file = paths.get(change.path)
        if (!file) {
          file = { path: change.path, additions: 0, deletions: 0 }
          paths.set(change.path, file)
          edits.files.push(file)
        }
        file.additions = addKnown(file.additions, change.additions)
        file.deletions = addKnown(file.deletions, change.deletions)
        edits.additions = addKnown(edits.additions, change.additions)
        edits.deletions = addKnown(edits.deletions, change.deletions)
      }
    }
  }
  revision.summary = turns
  return turns
}

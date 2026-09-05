import { describe, expect, test } from 'bun:test'
import type { ActivityItem, AgentSession } from '@shidou/client'
import { isRecordedEdit, recordedEditsByTurn } from './recorded-edits'
import { activityDisclosureSections } from './transcript-presentation'

function edit(id: string, file_changes: ActivityItem['file_changes'], overrides: Partial<ActivityItem> = {}): ActivityItem {
  return { id, source_id: id, kind: 'fileChange', title: 'Edit', detail: null, complete: true, failed: false, file_changes, ...overrides }
}

function block(turn_id: string | null, ...activities: ActivityItem[]): AgentSession['transcript_blocks'][number] {
  return { turn_id, after_message: 1, content: { kind: 'activities', data: activities } }
}

const known = { path: 'src/task.ts', additions: 3, deletions: 2, diff: '@@\n-old\n+new' }

describe('provider-recorded turn edits', () => {
  test('ignores unrelated workspace checkpoint files and separates other turns', () => {
    const own = edit('own', [known])
    const other = edit('other', [{ path: 'other-task.ts', additions: 90, deletions: 40 }])
    const session = {
      transcript_blocks: [block('task', own), block('other', other), block(null, other)],
      turns: [{ id: 'task', checkpoint: { status: 'ready', files: [{ path: 'workspace.ts', additions: 100, deletions: 100 }] } }],
    }
    const result = recordedEditsByTurn(session)
    expect([...result.keys()]).toEqual(['task', 'other'])
    expect(result.get('task')).toEqual({ files: [{ path: known.path, additions: 3, deletions: 2 }], additions: 3, deletions: 2, activities: [own] })
    expect(result.get('other')?.files.map((file) => file.path)).toEqual(['other-task.ts'])
  })

  test('excludes failed, incomplete, non-file-change, and unreported edits', () => {
    const result = recordedEditsByTurn({ transcript_blocks: [block('task',
      edit('failed', [known], { failed: true }),
      edit('incomplete', [known], { complete: false }),
      edit('shell', [known], { kind: 'command' }),
      edit('empty', []),
      edit('missing', undefined),
    )] })
    expect(result.size).toBe(0)
  })

  test('sums repeated edits to unique paths as recorded totals, retaining ordered diffs for review', () => {
    const first = edit('first', [known, { path: 'second.ts', additions: 1, deletions: 0 }])
    const second = edit('second', [{ ...known, additions: 2, deletions: 3, diff: '@@\n-new\n+old' }])
    const result = recordedEditsByTurn({ transcript_blocks: [block('task', first), block('task', second)] }).get('task')!
    expect(result.files).toEqual([
      { path: known.path, additions: 5, deletions: 5 },
      { path: 'second.ts', additions: 1, deletions: 0 },
    ])
    expect([result.additions, result.deletions]).toEqual([6, 5])
    expect(result.activities).toEqual([first, second])
    expect(result.activities[0]).toBe(first)
    expect(result.activities[1]!.file_changes![0]!.diff).toBe('@@\n-new\n+old')
  })

  test('keeps unknown counts unknown independently, even after subsequent known edits', () => {
    const result = recordedEditsByTurn({ transcript_blocks: [block('task',
      edit('first', [known]),
      edit('unknown', [{ path: known.path, additions: null, deletions: 4 }]),
      edit('last', [known, { path: 'unknown.ts', additions: 0 }]),
    )] }).get('task')!
    expect(result.files).toEqual([
      { path: known.path, additions: null, deletions: 8 },
      { path: 'unknown.ts', additions: 0, deletions: null },
    ])
    expect([result.additions, result.deletions]).toEqual([null, null])
  })

  test('has no fallback when no edits are reported, regardless of checkpoint readiness', () => {
    for (const status of ['ready', 'pending', 'failed']) {
      const session = {
        transcript_blocks: [],
        turns: [{ id: 'task', checkpoint: { status, files: [known] } }],
      }
      expect(recordedEditsByTurn(session).size).toBe(0)
    }
    expect(recordedEditsByTurn({ transcript_blocks: [block('task')] }).size).toBe(0)
  })

  test('reviews normalized per-activity diffs, never raw workspace output', () => {
    const activity = edit('own', [known, { path: 'missing.ts' }], {
      arguments: 'raw provider arguments',
      output: 'unrelated workspace output',
    })
    expect(activityDisclosureSections(activity)).toEqual([
      { kind: 'fileDiff', label: known.path, content: known.diff },
      { kind: 'fileDiff', label: 'missing.ts', content: 'No diff recorded for this edit.' },
    ])
  })

  test('localizes missing recorded diffs when a translator is provided', () => {
    const activity = edit('missing', [{ path: 'task.ts' }])
    const keys: string[] = []
    const sections = activityDisclosureSections(activity, (key) => {
      keys.push(key)
      return 'Localized missing diff'
    })
    expect(keys).toEqual(['transcript.recorded_edit_no_diff'])
    expect(sections[0]!.content).toBe('Localized missing diff')
    expect(activityDisclosureSections(activity)[0]!.content).toBe('No diff recorded for this edit.')
  })

  test('review expansion targets only successful, completed recorded edit rows', () => {
    expect(isRecordedEdit(edit('success', [known]))).toBe(true)
    expect(isRecordedEdit(edit('failed', [known], { failed: true }))).toBe(false)
    expect(isRecordedEdit(edit('pending', [known], { complete: false }))).toBe(false)
    expect(isRecordedEdit(edit('shell', [known], { kind: 'command' }))).toBe(false)
    expect(isRecordedEdit(edit('unreported', []))).toBe(false)
  })

  test('preserves patch whitespace and keeps failure output available in ordinary activity rows', () => {
    const diff = '@@\n-old\n+new  \n'
    expect(activityDisclosureSections(edit('success', [{ ...known, diff }]))[0]!.content).toBe(diff)
    expect(activityDisclosureSections(edit('failed', [known], { failed: true, output: 'Permission denied' })))
      .toEqual([{ kind: 'output', label: 'Output', content: 'Permission denied' }])
  })

  test('omits blank paths without normalizing exact path grouping or activity order', () => {
    const blank = edit('blank', [{ path: ' \t\n', additions: 99, deletions: 99 }])
    const first = edit('first', [
      { path: '', additions: null, deletions: null },
      { path: ' b.ts ', additions: 1, deletions: 0 },
      { path: 'b.ts', additions: 2, deletions: 1 },
    ])
    const last = edit('last', [{ path: ' b.ts ', additions: 3, deletions: 2 }])
    const result = recordedEditsByTurn({ transcript_blocks: [block('task', blank, first, last)] }).get('task')!
    expect(isRecordedEdit(blank)).toBe(false)
    expect(recordedEditsByTurn({ transcript_blocks: [block('blank-only', blank)] }).size).toBe(0)
    expect(result.files).toEqual([
      { path: ' b.ts ', additions: 4, deletions: 2 },
      { path: 'b.ts', additions: 2, deletions: 1 },
    ])
    expect([result.additions, result.deletions]).toEqual([6, 3])
    expect(result.activities.map((activity) => activity.id)).toEqual(['first', 'last'])
    expect(activityDisclosureSections(first).map((section) => section.label)).toEqual([' b.ts ', 'b.ts'])
  })

  test('marks totals beyond safe JavaScript integer precision as unknown', () => {
    const result = recordedEditsByTurn({ transcript_blocks: [block('task',
      edit('first', [{ path: 'a.ts', additions: Number.MAX_SAFE_INTEGER, deletions: 0 }]),
      edit('last', [{ path: 'a.ts', additions: 1, deletions: 2 }]),
    )] }).get('task')!
    expect(result.files[0]).toEqual({ path: 'a.ts', additions: null, deletions: 2 })
    expect([result.additions, result.deletions]).toEqual([null, 2])
  })

  test('reuses cached summaries without sharing independently created transcript snapshots', () => {
    const session = { transcript_blocks: [block('task', edit('first', [known]))] }
    const first = recordedEditsByTurn(session)
    expect(recordedEditsByTurn(session)).toBe(first)
    const next = recordedEditsByTurn({ transcript_blocks: [...session.transcript_blocks, block('task', edit('second', [known]))] })
    expect(next).not.toBe(first)
    expect(next.get('task')?.additions).toBe(6)
    expect(first.get('task')?.additions).toBe(3)
  })
})

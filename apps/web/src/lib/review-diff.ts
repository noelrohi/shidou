import {
  parsePatchFiles,
  trimPatchContext,
  type FileContents,
  type FileDiffContentsLoader,
  type FileDiffMetadata,
} from '@pierre/diffs'
import type { AgentSession, ReviewDiffSource } from '@shidou/client'

const REVIEW_DIFF_CONTEXT_LINES = 3

export function latestReviewTurnSource(session: AgentSession | null): ReviewDiffSource | null {
  if (!session) return null
  let turn: AgentSession['turns'][number] | undefined
  for (let index = session.turns.length - 1; index >= 0; index -= 1) {
    const candidate = session.turns[index]!
    if (candidate.turn_count > 0 && candidate.checkpoint?.status === 'ready') {
      turn = candidate
      break
    }
  }
  return turn
    ? {
        lastTurn: {
          session_id: session.id,
          turn_id: turn.id,
          turn_count: turn.turn_count,
        },
      }
    : null
}

/**
 * The remembered review range, stored as an intent rather than a literal
 * source. A range naming a turn cannot be carried into a session that does not
 * have that turn, so what persists is the mode and each session resolves it.
 */
export type ReviewDiffMode =
  | 'lastTurn'
  | 'uncommitted'
  | 'unstaged'
  | 'staged'
  | 'committed'
  | 'branch'
  | { turn: number }

const REVIEW_DIFF_MODE_KEY = 'shidou.reviewDiffMode'

/**
 * The newest turn in `session` holding a ready checkpoint, optionally pinned to
 * one turn number. Both the mode mapping and the toolbar's "last turn" entry
 * resolve a turn this way, so the walk lives here rather than in each.
 */
function readyTurnSource(
  session: AgentSession | null,
  turnCount?: number,
): ReviewDiffSource | null {
  if (!session) return null
  for (let index = session.turns.length - 1; index >= 0; index -= 1) {
    const turn = session.turns[index]!
    if (
      turn.turn_count > 0
      && (turnCount === undefined || turn.turn_count === turnCount)
      && turn.checkpoint?.status === 'ready'
    ) {
      return { lastTurn: { session_id: session.id, turn_id: turn.id, turn_count: turn.turn_count } }
    }
  }
  return null
}

/**
 * Resolve the remembered mode against one session. A turn-scoped mode has to
 * degrade: the turn it names may not exist here, and a session may have no
 * ready checkpoint at all, so both fall back rather than showing nothing.
 */
export function reviewDiffSourceForMode(
  mode: ReviewDiffMode,
  session: AgentSession | null,
): ReviewDiffSource {
  if (mode === 'lastTurn') return readyTurnSource(session) ?? 'uncommitted'
  if (typeof mode === 'object') {
    return readyTurnSource(session, mode.turn) ?? readyTurnSource(session) ?? 'uncommitted'
  }
  return mode
}

/** The mode an explicit pick from the diff toolbar should be remembered as. */
export function reviewDiffModeForSource(
  source: ReviewDiffSource,
  latest: ReviewDiffSource | null,
): ReviewDiffMode {
  if (typeof source === 'object') {
    return latest && sameReviewDiffSource(source, latest)
      ? 'lastTurn'
      : { turn: source.lastTurn.turn_count }
  }
  return source
}

export function readReviewDiffMode(): ReviewDiffMode {
  if (typeof window === 'undefined') return 'uncommitted'
  try {
    return parseReviewDiffMode(JSON.parse(window.localStorage.getItem(REVIEW_DIFF_MODE_KEY) ?? 'null'))
  } catch {
    return 'uncommitted'
  }
}

export function writeReviewDiffMode(mode: ReviewDiffMode) {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(REVIEW_DIFF_MODE_KEY, JSON.stringify(mode))
  } catch {
    // Reviewing still works when browser storage is unavailable.
  }
}

export function parseReviewDiffMode(value: unknown): ReviewDiffMode {
  if (
    value === 'lastTurn' || value === 'uncommitted' || value === 'unstaged'
    || value === 'staged' || value === 'committed' || value === 'branch'
  ) {
    return value
  }
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const turn = (value as { turn?: unknown }).turn
    if (typeof turn === 'number' && Number.isInteger(turn) && turn > 0) return { turn }
  }
  return 'uncommitted'
}

export function sameReviewDiffSource(
  left: ReviewDiffSource,
  right: ReviewDiffSource,
): boolean {
  if (typeof left === 'string' || typeof right === 'string') return left === right
  return left.lastTurn.session_id === right.lastTurn.session_id
    && left.lastTurn.turn_id === right.lastTurn.turn_id
    && left.lastTurn.turn_count === right.lastTurn.turn_count
}

export function reviewDiffSourceLabel(
  source: ReviewDiffSource,
  latest: ReviewDiffSource | null,
  t?: (key: string, params?: Record<string, string | number>) => string,
): string {
  if (typeof source === 'object') {
    return latest && sameReviewDiffSource(source, latest)
      ? t ? t('diff.source_last_turn') : 'Last turn'
      : t ? t('diff.source_turn', { turn: source.lastTurn.turn_count }) : `Turn ${source.lastTurn.turn_count}`
  }
  if (t) return t({
    uncommitted: 'diff.source_uncommitted',
    unstaged: 'diff.source_unstaged',
    staged: 'diff.source_staged',
    committed: 'diff.source_committed',
    branch: 'diff.source_branch',
  }[source])
  return {
    uncommitted: 'Uncommitted',
    unstaged: 'Unstaged',
    staged: 'Staged',
    committed: 'Committed',
    branch: 'Branch',
  }[source]
}

export function compactReviewPatch(patch: string): string {
  // trimPatchContext handles one unified file patch at a time. Feeding it a
  // multi-file Git patch makes the following `diff --git` header look like
  // hunk contents, which produces invalid line counts.
  return patch
    .split(/(?=^diff --git )/m)
    .map((filePatch) => trimPatchContext(filePatch, REVIEW_DIFF_CONTEXT_LINES))
    .join('')
}

export function createReviewDiffLoader(
  patch: string,
  cacheKeyPrefix: string,
): FileDiffContentsLoader {
  let hydratedFiles: Map<string, FileDiffMetadata> | undefined

  return async (fileDiff) => {
    hydratedFiles ??= new Map(
      parsePatchFiles(patch, `${cacheKeyPrefix}:full`, true)
        .flatMap((entry) => entry.files)
        .map((file) => [fileIdentity(file), file]),
    )
    const hydrated = hydratedFiles.get(fileIdentity(fileDiff))
    if (!hydrated) throw new Error(`Could not hydrate diff context for ${fileDiff.name}`)

    const newFile = fileContents(hydrated, 'new')
    if (hydrated.type === 'rename-pure') return { oldFile: null, newFile }
    return {
      oldFile: fileContents(hydrated, 'old'),
      newFile,
    }
  }
}

function fileIdentity(file: FileDiffMetadata): string {
  return `${file.prevName ?? ''}\0${file.name}\0${file.type}`
}

function fileContents(file: FileDiffMetadata, side: 'old' | 'new'): FileContents {
  return {
    name: side === 'old' ? file.prevName ?? file.name : file.name,
    contents: (side === 'old' ? file.deletionLines : file.additionLines).join(''),
    cacheKey: file.cacheKey ? `${file.cacheKey}:${side}` : undefined,
  }
}

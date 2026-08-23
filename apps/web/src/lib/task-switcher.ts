import type { AgentSession } from '@waku/client'

export const TASK_SWITCHER_MAX_TASKS = 10
export const TASK_SWITCHER_MAX_COLUMNS = 5

/**
 * The order is snapshotted when the switcher opens: the current task first,
 * then previously visited tasks, capped at ten. Tasks the user never visited
 * stay out so opening old windows cannot masquerade as recency.
 */
export function orderedTaskIds(
  current: string | undefined,
  recent: readonly string[],
  startedTaskIds: readonly string[],
): string[] {
  const valid = new Set(startedTaskIds)
  const ordered: string[] = []
  const push = (id: string) => {
    if (ordered.length < TASK_SWITCHER_MAX_TASKS && valid.has(id) && !ordered.includes(id)) {
      ordered.push(id)
    }
  }
  if (current) push(current)
  for (const id of recent) push(id)
  return ordered
}

/** The first forward press targets the previous task; reverse wraps to the end. */
export function initialHighlightIndex(
  ordered: readonly string[],
  current: string | undefined,
  reverse: boolean,
): number | null {
  if (!ordered.length) return null
  if (ordered[0] === current) {
    if (ordered.length === 1) return 0
    return reverse ? ordered.length - 1 : 1
  }
  return reverse ? ordered.length - 1 : 0
}

export function cycleHighlightIndex(current: number, count: number, reverse: boolean): number {
  if (count <= 0) return 0
  return reverse ? (current - 1 + count) % count : (current + 1) % count
}

export function taskSwitcherColumns(count: number): number {
  const capped = Math.min(count, TASK_SWITCHER_MAX_TASKS)
  if (capped <= TASK_SWITCHER_MAX_COLUMNS) return Math.max(1, capped)
  return Math.ceil(capped / 2)
}

export function recordTaskAccess(recent: readonly string[], sessionId: string): string[] {
  return [sessionId, ...recent.filter((id) => id !== sessionId)]
}

export function taskSwitcherPreview(session: AgentSession): string {
  for (let index = session.messages.length - 1; index >= 0; index -= 1) {
    const message = session.messages[index]!
    if (message.role !== 'assistant' && message.role !== 'user') continue
    const content = (message.display_content ?? message.content).trim()
    if (content) return content.slice(0, 400)
  }
  return ''
}

import type { AgentSession, Project } from '@shidou/client'
import { isProjectlessProject, projectDisplayName } from './project-presentation'

export type DateGroup = 'today' | 'yesterday' | 'week' | 'month' | 'year' | 'more'
export type SidebarGrouping = 'updated' | 'project'
export type SidebarOrdering = 'newest' | 'oldest'

export interface SessionItem {
  session: AgentSession
  projectName: string
  projectPath: string | null
  branch: string | null
  timestamp: number
}

/**
 * A collapsible sidebar section. Keys are stable across grouping switches so
 * each view's disclosure state survives toggling between Project and Updated.
 */
export interface SessionGroup {
  key: string
  kind: 'date' | 'project' | 'projectless'
  dateId?: DateGroup
  project?: Project
  label: string
  sessions: SessionItem[]
  showMore: boolean
}

export type SidebarListRow =
  | { kind: 'search'; key: 'search' }
  | { kind: 'group'; key: string; group: SessionGroup; collapsed: boolean; first: boolean }
  | { kind: 'session'; key: string; item: SessionItem; guides: boolean }
  | { kind: 'showMore'; key: string; group: SessionGroup }
  | { kind: 'spacer'; key: string }

const GROUP_LABELS: Record<DateGroup, string> = {
  today: 'Today',
  yesterday: 'Yesterday',
  week: 'This Week',
  month: 'This Month',
  year: 'This Year',
  more: 'More',
}

const GROUP_ORDER: DateGroup[] = ['today', 'yesterday', 'week', 'month', 'year', 'more']

/** Project groups list only the last three days up front; older sessions reveal in batches. */
const PROJECT_RECENT_WINDOW_SECONDS = 3 * 24 * 60 * 60
export const PROJECT_REVEAL_BATCH = 30

export function sidebarRows(
  groups: SessionGroup[],
  collapsed: ReadonlySet<string>,
): SidebarListRow[] {
  const rows: SidebarListRow[] = [{ kind: 'search', key: 'search' }]
  const hasHistory = groups.some((group) => group.sessions.length || group.showMore)
  groups.forEach((group, index) => {
    const isCollapsed = collapsed.has(group.key)
    rows.push({
      kind: 'group',
      key: `group:${group.key}`,
      group,
      collapsed: isCollapsed,
      first: index === 0,
    })
    if (!isCollapsed) {
      const guides = group.kind !== 'date'
      rows.push(...group.sessions.map((item) => ({
        kind: 'session' as const,
        key: `session:${item.session.id}`,
        item,
        guides,
      })))
      if (group.showMore) {
        rows.push({ kind: 'showMore', key: `show-more:${group.key}`, group })
      }
    }
    if (hasHistory) rows.push({ kind: 'spacer', key: `spacer:${group.key}` })
  })
  return rows
}

export function sidebarGroups(
  projects: Project[],
  sessions: AgentSession[],
  options: {
    grouping: SidebarGrouping
    ordering: SidebarOrdering
    now?: Date
    revealed?: ReadonlyMap<string, number>
    unknownProject?: string
    projectlessName?: string
  },
): SessionGroup[] {
  const {
    grouping,
    ordering,
    now = new Date(),
    revealed,
    unknownProject = 'Unknown project',
    projectlessName = 'No project',
  } = options
  const projectById = new Map(projects.map((project) => [project.id, project]))
  const started = sessions
    .filter(sessionHasStarted)
    .sort((left, right) => ordering === 'oldest'
      ? sessionTimestamp(left) - sessionTimestamp(right)
      : sessionTimestamp(right) - sessionTimestamp(left))
  const item = (session: AgentSession): SessionItem => {
    const project = projectById.get(session.project_id)
    return {
      session,
      projectName: project ? projectDisplayName(project, projectlessName) : unknownProject,
      projectPath: project?.path ?? null,
      branch: session.workspace?.kind === 'worktree' ? session.workspace.branch : null,
      timestamp: sessionTimestamp(session),
    }
  }

  const groups = grouping === 'project'
    ? projectGroups(started, projectById, item, now, revealed, unknownProject, projectlessName)
    : dateGroups(started, item, now, ordering)
  if (groups.length) return groups
  // Keep the first header visible so the header actions never disappear
  // merely because there is no task history yet.
  return [grouping === 'project'
    ? { key: 'projectless', kind: 'projectless', label: projectlessName, sessions: [], showMore: false }
    : { key: 'updated:today', kind: 'date', dateId: 'today', label: GROUP_LABELS.today, sessions: [], showMore: false }]
}

function dateGroups(
  started: AgentSession[],
  item: (session: AgentSession) => SessionItem,
  now: Date,
  ordering: SidebarOrdering,
): SessionGroup[] {
  const grouped = new Map<DateGroup, SessionItem[]>()
  for (const session of started) {
    const id = dateGroup(sessionTimestamp(session), now)
    const items = grouped.get(id) ?? []
    items.push(item(session))
    grouped.set(id, items)
  }
  const order = ordering === 'oldest' ? [...GROUP_ORDER].reverse() : GROUP_ORDER
  return order
    .filter((id) => grouped.has(id))
    .map((id) => ({
      key: `updated:${id}`,
      kind: 'date' as const,
      dateId: id,
      label: GROUP_LABELS[id],
      sessions: grouped.get(id)!,
      showMore: false,
    }))
}

function projectGroups(
  started: AgentSession[],
  projectById: ReadonlyMap<string, Project>,
  item: (session: AgentSession) => SessionItem,
  now: Date,
  revealed: ReadonlyMap<string, number> | undefined,
  unknownProject: string,
  projectlessName: string,
): SessionGroup[] {
  const groups: SessionGroup[] = []
  const indexByProject = new Map<string, number>()
  const projectless: SessionItem[] = []
  for (const session of started) {
    const project = projectById.get(session.project_id)
    if (project && isProjectlessProject(project)) {
      projectless.push(item(session))
      continue
    }
    let index = indexByProject.get(session.project_id)
    if (index === undefined) {
      index = groups.length
      indexByProject.set(session.project_id, index)
      groups.push({
        key: `project:${session.project_id}`,
        kind: 'project',
        project,
        label: project ? projectDisplayName(project, projectlessName) : unknownProject,
        sessions: [],
        showMore: false,
      })
    }
    groups[index]!.sessions.push(item(session))
  }
  if (projectless.length) {
    groups.push({
      key: 'projectless',
      kind: 'projectless',
      label: projectlessName,
      sessions: projectless,
      showMore: false,
    })
  }
  const recentCutoff = Math.floor(now.getTime() / 1_000) - PROJECT_RECENT_WINDOW_SECONDS
  for (const group of groups) {
    const revealedOlder = revealed?.get(group.key) ?? 0
    const visible: SessionItem[] = []
    let olderSeen = 0
    for (const entry of group.sessions) {
      const recent = entry.timestamp >= recentCutoff
      if (recent || olderSeen < revealedOlder) visible.push(entry)
      if (!recent) olderSeen += 1
    }
    group.showMore = olderSeen > revealedOlder
    group.sessions = visible
  }
  return groups
}

export function sessionHasStarted(session: AgentSession): boolean {
  return Boolean(
    session.turns.length
      || session.messages.length
      || session.provider_cursor
      || session.last_reply_at,
  )
}

export function sessionTimeLabel(
  session: AgentSession,
  nowSeconds = Math.floor(Date.now() / 1_000),
  t?: Translator,
): string | null {
  const turn = session.turns.at(-1)
  if (
    (session.status === 'connecting' || session.status === 'working' || session.status === 'waiting')
      && turn?.status === 'running'
  ) {
    const elapsed = Math.max(0, nowSeconds - turn.started_at)
    return t
      ? t('sidebar.working', { elapsed: formatWorkingElapsedLocalized(elapsed, t) })
      : `Working for ${formatWorkingElapsed(elapsed)}`
  }
  if (session.last_reply_at == null) return null
  const elapsed = Math.max(0, nowSeconds - session.last_reply_at)
  return t ? formatTimeAgoLocalized(elapsed, t) : formatTimeAgo(elapsed)
}

export function nextSidebarUpdateDelay(
  sessions: AgentSession[],
  nowSeconds = Math.floor(Date.now() / 1_000),
): number {
  let next = secondsUntilLocalMidnight(nowSeconds)
  for (const session of sessions) {
    const turn = session.turns.at(-1)
    if (
      (session.status === 'connecting' || session.status === 'working' || session.status === 'waiting')
        && turn?.status === 'running'
    ) {
      return 1
    }
    if (session.last_reply_at == null) continue
    const elapsed = Math.max(0, nowSeconds - session.last_reply_at)
    const step = elapsed < 3_600 ? 60 : elapsed < 86_400 ? 3_600 : 86_400
    const remaining = Math.max(1, step - elapsed % step)
    next = Math.min(next, remaining)
  }
  return next
}

export function dateGroup(timestamp: number, now = new Date()): DateGroup {
  const date = new Date(timestamp * 1_000)
  const today = localDateStart(now)
  const sessionDay = localDateStart(date)
  if (sessionDay >= today) return 'today'

  const yesterday = new Date(today)
  yesterday.setDate(yesterday.getDate() - 1)
  if (sessionDay.getTime() === yesterday.getTime()) return 'yesterday'

  const weekStart = new Date(today)
  weekStart.setDate(weekStart.getDate() - ((weekStart.getDay() + 6) % 7))
  if (sessionDay >= weekStart) return 'week'

  if (
    sessionDay.getFullYear() === today.getFullYear()
      && sessionDay.getMonth() === today.getMonth()
  ) return 'month'
  if (sessionDay.getFullYear() === today.getFullYear()) return 'year'
  return 'more'
}

export function formatTimeAgo(seconds: number): string {
  if (seconds < 60) return 'just now'
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h`
  return `${Math.floor(seconds / 86_400)}d`
}

export function formatWorkingElapsed(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3_600) {
    const minutes = Math.floor(seconds / 60)
    const remainder = seconds % 60
    return remainder ? `${minutes}m ${remainder}s` : `${minutes}m`
  }
  const hours = Math.floor(seconds / 3_600)
  const minutes = Math.floor((seconds % 3_600) / 60)
  return minutes ? `${hours}h ${minutes}m` : `${hours}h`
}

function formatTimeAgoLocalized(seconds: number, t: Translator): string {
  if (seconds < 60) return t('sidebar.just_now')
  if (seconds < 3_600) return t('sidebar.minutes_ago', { count: Math.floor(seconds / 60) })
  if (seconds < 86_400) return t('sidebar.hours_ago', { count: Math.floor(seconds / 3_600) })
  return t('sidebar.days_ago', { count: Math.floor(seconds / 86_400) })
}

function formatWorkingElapsedLocalized(seconds: number, t: Translator): string {
  if (seconds < 60) return t('duration.seconds_short', { count: seconds })
  if (seconds < 3_600) {
    const minutes = Math.floor(seconds / 60)
    const remainder = seconds % 60
    const first = t('duration.minutes_short', { count: minutes })
    return remainder
      ? t('duration.two_units', { first, second: t('duration.seconds_short', { count: remainder }) })
      : first
  }
  const hours = Math.floor(seconds / 3_600)
  const minutes = Math.floor((seconds % 3_600) / 60)
  const first = t('duration.hours_short', { count: hours })
  return minutes
    ? t('duration.two_units', { first, second: t('duration.minutes_short', { count: minutes }) })
    : first
}

type Translator = (key: string, params?: Record<string, string | number>) => string

function sessionTimestamp(session: AgentSession): number {
  return session.last_reply_at ?? session.created_at
}

function localDateStart(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

function secondsUntilLocalMidnight(nowSeconds: number): number {
  const now = new Date(nowSeconds * 1_000)
  const tomorrow = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
  return Math.max(1, Math.ceil((tomorrow.getTime() - now.getTime()) / 1_000))
}

import { describe, expect, test } from 'bun:test'
import type { AgentSession, Project } from '@shidou/client'
import {
  dateGroup,
  formatTimeAgo,
  formatWorkingElapsed,
  nextSidebarUpdateDelay,
  sessionHasStarted,
  sessionTimeLabel,
  sidebarGroups,
  sidebarRows,
  PROJECT_REVEAL_BATCH,
  SHELF_GROUP_KEY,
} from './sidebar-presentation'

describe('desktop sidebar presentation', () => {
  test('uses a Monday-based current week instead of a rolling seven days', () => {
    const wednesday = new Date(2026, 7, 12, 12)
    expect(dateGroup(atLocalNoon(2026, 7, 12), wednesday)).toBe('today')
    expect(dateGroup(atLocalNoon(2026, 7, 11), wednesday)).toBe('yesterday')
    expect(dateGroup(atLocalNoon(2026, 7, 10), wednesday)).toBe('week')
    expect(dateGroup(atLocalNoon(2026, 7, 9), wednesday)).toBe('month')
  })

  test('keeps header actions in an empty history through the first group header', () => {
    const empty = sidebarGroups([], [], { grouping: 'updated', ordering: 'newest' })
    expect(sidebarRows(empty, new Set())).toEqual([
      { kind: 'search', key: 'search' },
      {
        kind: 'group',
        key: 'group:updated:today',
        group: {
          key: 'updated:today',
          kind: 'date',
          dateId: 'today',
          label: 'Today',
          sessions: [],
          showMore: false,
        },
        collapsed: false,
        first: true,
      },
    ])
    const emptyProjects = sidebarGroups([], [], { grouping: 'project', ordering: 'newest' })
    expect(emptyProjects[0]?.kind).toBe('projectless')
  })

  test('groups by project in recency order with the projectless group last', () => {
    const projects: Project[] = [
      { id: 'a', name: 'Alpha', path: '/work/alpha', created_at: 1, workspace_default: 'local' },
      { id: 'b', name: 'Beta', path: '/work/beta', created_at: 1, workspace_default: 'local' },
      {
        id: 'p',
        name: 'No project',
        path: '/home/me/.shidou/projects/x',
        created_at: 1,
        workspace_default: 'local',
      },
    ]
    const now = new Date(2026, 7, 15, 12)
    const nowSeconds = Math.floor(now.getTime() / 1_000)
    const sessions = [
      session({ id: 'old-a', project_id: 'a', last_reply_at: nowSeconds - 9 * 86_400 }),
      session({ id: 'new-b', project_id: 'b', last_reply_at: nowSeconds - 60 }),
      session({ id: 'new-a', project_id: 'a', last_reply_at: nowSeconds - 120 }),
      session({ id: 'loose', project_id: 'p', last_reply_at: nowSeconds - 30 }),
    ]
    const groups = sidebarGroups(projects, sessions, { grouping: 'project', ordering: 'newest', now })
    expect(groups.map((group) => group.key)).toEqual(['project:b', 'project:a', 'projectless'])
    expect(groups[2]?.label).toBe('No project')
    const alpha = groups[1]!
    expect(alpha.sessions.map((item) => item.session.id)).toEqual(['new-a'])
    expect(alpha.showMore).toBe(true)
    const revealed = sidebarGroups(projects, sessions, {
      grouping: 'project',
      ordering: 'newest',
      now,
      revealed: new Map([['project:a', 30]]),
    })
    expect(revealed[1]?.sessions.map((item) => item.session.id)).toEqual(['new-a', 'old-a'])
    expect(revealed[1]?.showMore).toBe(false)
  })

  test('oldest ordering reverses sessions and date-group order', () => {
    const now = new Date(2026, 7, 15, 12)
    const nowSeconds = Math.floor(now.getTime() / 1_000)
    const sessions = [
      session({ id: 'today', last_reply_at: nowSeconds - 60 }),
      session({ id: 'older', last_reply_at: nowSeconds - 30 * 86_400 }),
    ]
    const groups = sidebarGroups([], sessions, { grouping: 'updated', ordering: 'oldest', now })
    expect(groups.map((group) => group.dateId)).toEqual(['year', 'today'])
  })

  test('project-grouped rows carry guides and show-more rows', () => {
    const projects: Project[] = [
      {
        id: 'a',
        name: 'Alpha',
        path: '/work/alpha',
        created_at: 1,
        workspace_default: 'local',
      },
    ]
    const now = new Date(2026, 7, 15, 12)
    const nowSeconds = Math.floor(now.getTime() / 1_000)
    const sessions = [
      session({ id: 'fresh', project_id: 'a', last_reply_at: nowSeconds - 60 }),
      session({ id: 'stale', project_id: 'a', last_reply_at: nowSeconds - 9 * 86_400 }),
    ]
    const groups = sidebarGroups(projects, sessions, { grouping: 'project', ordering: 'newest', now })
    const rows = sidebarRows(groups, new Set())
    expect(rows.map((row) => row.kind)).toEqual(['search', 'group', 'session', 'showMore', 'spacer'])
    const sessionRow = rows[2]!
    expect(sessionRow.kind === 'session' && sessionRow.guides).toBe(true)
    expect(sidebarRows(groups, new Set(['project:a'])).map((row) => row.kind))
      .toEqual(['search', 'group', 'spacer'])
  })

  test('matches desktop settled and live time labels', () => {
    expect(formatTimeAgo(0)).toBe('just now')
    expect(formatTimeAgo(604_800)).toBe('7d')
    expect(formatWorkingElapsed(65)).toBe('1m 5s')
    expect(formatWorkingElapsed(3_720)).toBe('1h 2m')

    const live = session({
      status: 'working',
      turns: [{
        id: 'turn',
        turn_count: 1,
        status: 'running',
        provider_turn_started: true,
        started_at: 100,
        completed_at: null,
        checkpoint: null,
      }],
    })
    expect(sessionTimeLabel(live, 165)).toBe('Working for 1m 5s')
    expect(nextSidebarUpdateDelay([live], 165)).toBe(1)
  })

  test('does not invent a reply time and keeps cursor-only resumed tasks', () => {
    const resumed = session({ provider_cursor: { provider: 'codex', value: {} } as never })
    expect(sessionHasStarted(resumed)).toBe(true)
    expect(sessionTimeLabel(resumed, 1_000)).toBeNull()
  })

  test('gathers archived tasks in one shelf after every group, in both groupings', () => {
    const projects: Project[] = [
      { id: 'a', name: 'Alpha', path: '/work/alpha', created_at: 1, workspace_default: 'local' },
      { id: 'b', name: 'Beta', path: '/work/beta', created_at: 1, workspace_default: 'local' },
    ]
    const now = new Date(2026, 7, 15, 12)
    const nowSeconds = Math.floor(now.getTime() / 1_000)
    const sessions = [
      session({ id: 'active-a', project_id: 'a', last_reply_at: nowSeconds - 60 }),
      session({ id: 'active-b', project_id: 'b', last_reply_at: nowSeconds - 90 }),
      session({
        id: 'shelved-old',
        project_id: 'a',
        last_reply_at: nowSeconds - 120,
        archived_at: nowSeconds - 500,
      }),
      session({
        id: 'shelved-new',
        project_id: 'b',
        last_reply_at: nowSeconds - 30,
        archived_at: nowSeconds - 5,
      }),
    ]
    for (const grouping of ['updated', 'project'] as const) {
      const groups = sidebarGroups(projects, sessions, { grouping, ordering: 'newest', now })
      const shelves = groups.filter((group) => group.kind === 'shelf')
      expect(shelves).toHaveLength(1)
      expect(groups.at(-1)).toBe(shelves[0]!)
      expect(shelves[0]!.key).toBe(SHELF_GROUP_KEY)
      // Newest-archived first, whatever the sidebar's own ordering says.
      expect(shelves[0]!.sessions.map((item) => item.session.id))
        .toEqual(['shelved-new', 'shelved-old'])
      // No archived task survives anywhere above the shelf.
      expect(
        groups
          .slice(0, -1)
          .flatMap((group) => group.sessions.map((item) => item.session.id))
          .sort(),
      ).toEqual(['active-a', 'active-b'])
    }
  })

  test('omits the shelf when nothing is archived and keeps the fallback header', () => {
    const now = new Date(2026, 7, 15, 12)
    const nowSeconds = Math.floor(now.getTime() / 1_000)
    const active = sidebarGroups([], [session({ id: 'live', last_reply_at: nowSeconds })], {
      grouping: 'updated',
      ordering: 'newest',
      now,
    })
    expect(active.some((group) => group.kind === 'shelf')).toBe(false)

    // Only archived history: the empty first header still carries the sidebar
    // actions, and the shelf follows it.
    const onlyArchived = sidebarGroups([], [
      session({ id: 'shelved', last_reply_at: nowSeconds, archived_at: nowSeconds }),
    ], { grouping: 'updated', ordering: 'newest', now })
    expect(onlyArchived.map((group) => group.kind)).toEqual(['date', 'shelf'])
    expect(onlyArchived[0]!.sessions).toEqual([])
    expect(onlyArchived[1]!.sessions.map((item) => item.session.id)).toEqual(['shelved'])
  })

  test('pages the shelf and counts every archived task in its header', () => {
    const now = new Date(2026, 7, 15, 12)
    const nowSeconds = Math.floor(now.getTime() / 1_000)
    const total = PROJECT_REVEAL_BATCH + 5
    const sessions = Array.from({ length: total }, (_, index) => session({
      id: `shelved-${index}`,
      last_reply_at: nowSeconds - index,
      archived_at: nowSeconds - index,
    }))
    const shelf = sidebarGroups([], sessions, {
      grouping: 'updated',
      ordering: 'newest',
      now,
      shelfLabel: (count) => `Task Shelf (${count})`,
    }).at(-1)!
    expect(shelf.label).toBe(`Task Shelf (${total})`)
    expect(shelf.sessions).toHaveLength(PROJECT_REVEAL_BATCH)
    expect(shelf.showMore).toBe(true)

    const revealed = sidebarGroups([], sessions, {
      grouping: 'updated',
      ordering: 'newest',
      now,
      revealed: new Map([[SHELF_GROUP_KEY, PROJECT_REVEAL_BATCH]]),
    }).at(-1)!
    expect(revealed.sessions).toHaveLength(total)
    expect(revealed.showMore).toBe(false)

    // Collapsed by default in the row list; open, it ends with its show-more.
    const groups = sidebarGroups([], sessions, { grouping: 'updated', ordering: 'newest', now })
    expect(sidebarRows(groups, new Set([SHELF_GROUP_KEY])).filter((row) => row.kind === 'session'))
      .toEqual([])
    const open = sidebarRows(groups, new Set())
    expect(open.at(-2)?.kind).toBe('showMore')
    const shelfSession = open.find((row) => row.kind === 'session' && row.item.session.id === 'shelved-0')
    expect(shelfSession?.kind === 'session' && shelfSession.guides).toBe(false)
  })

  test('presents the projectless sentinel with the localized desktop name', () => {
    const project: Project = {
      id: 'project',
      name: 'No project',
      path: '/home/me/.shidou/projects/session',
      created_at: 1,
      workspace_default: 'local',
    }
    const groups = sidebarGroups(
      [project],
      [session({ messages: [{ id: 'message' } as never] })],
      {
        grouping: 'updated',
        ordering: 'newest',
        now: new Date(2026, 7, 15, 12),
        unknownProject: 'Unknown project',
        projectlessName: 'プロジェクトなし',
      },
    )
    expect(groups[0]?.sessions[0]?.projectName).toBe('プロジェクトなし')
  })
})

function atLocalNoon(year: number, month: number, day: number): number {
  return Math.floor(new Date(year, month, day, 12).getTime() / 1_000)
}

function session(patch: Partial<AgentSession>): AgentSession {
  return {
    id: 'session',
    title: 'New Task',
    project_id: 'project',
    provider: 'codex',
    model: null,
    runtime_mode: 'ask',
    interaction_mode: 'build',
    status: 'idle',
    created_at: 10,
    updated_at: 10,
    provider_cursor: null,
    messages: [],
    transcript_blocks: [],
    turns: [],
    ...patch,
  }
}

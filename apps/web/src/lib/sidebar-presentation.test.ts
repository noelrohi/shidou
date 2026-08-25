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

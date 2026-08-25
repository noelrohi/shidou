import { describe, expect, test } from 'bun:test'
import {
  projectRemovalDestination,
  readRememberedNavigation,
  routeDestinationTransition,
  taskRemovalDestination,
  writeRememberedNavigation,
} from './navigation-memory'
import { createProject, createSession } from './daemon-api'

describe('remembered navigation', () => {
  test('restores a new task and its project per daemon', () => {
    const storage = memoryStorage()
    writeRememberedNavigation(storage, 'ws://first', {
      kind: 'newTask',
      projectId: 'shidou',
    })
    writeRememberedNavigation(storage, 'ws://second', {
      kind: 'session',
      sessionId: 'session-2',
    })

    expect(readRememberedNavigation(storage, 'ws://first')).toEqual({
      kind: 'newTask',
      projectId: 'shidou',
    })
    expect(readRememberedNavigation(storage, 'ws://second')).toEqual({
      kind: 'session',
      sessionId: 'session-2',
    })
  })

  test('ignores malformed state', () => {
    const storage = memoryStorage('{broken')
    expect(readRememberedNavigation(storage, 'ws://first')).toBeNull()
  })
})

describe('browser route transitions', () => {
  test('Back from New Task activates the session in the URL', () => {
    expect(routeDestinationTransition(undefined, 'session-1', true)).toBe('session')
  })

  test('Forward from a session restores the New Task route', () => {
    expect(routeDestinationTransition('session-1', undefined, false)).toBe('newTask')
  })

  test('an explicit New Task transition does not reinitialize its draft', () => {
    expect(routeDestinationTransition('session-1', undefined, true)).toBeNull()
  })
})

describe('selected task removal', () => {
  test('opens the newest remaining task in the same project', () => {
    const project = { ...createProject('/repos/shidou'), id: 'shidou' }
    const removed = { ...createSession(project.id, 'codex', 'local'), id: 'removed' }
    const older = {
      ...createSession(project.id, 'codex', 'local'),
      id: 'older',
      updated_at: 10,
    }
    const newer = {
      ...createSession(project.id, 'claude', 'local'),
      id: 'newer',
      updated_at: 20,
    }

    expect(taskRemovalDestination(
      [project],
      [project],
      [older, newer],
      removed,
    )).toEqual({ kind: 'session', sessionId: 'newer' })
  })

  test('opens a fresh task in the same ordinary project when history is empty', () => {
    const project = { ...createProject('/repos/shidou'), id: 'shidou' }
    const removed = createSession(project.id, 'codex', 'local')
    expect(taskRemovalDestination([project], [project], [], removed)).toEqual({
      kind: 'newTask',
      project,
    })
  })

  test('creates a fresh projectless workspace after deleting its last task', () => {
    const project = {
      ...createProject('/home/user/.shidou/projects/old-task'),
      id: 'projectless',
      name: 'No project',
    }
    const removed = createSession(project.id, 'codex', 'local')
    expect(taskRemovalDestination([project], [], [], removed)).toEqual({
      kind: 'projectless',
    })
  })
})

describe('project removal', () => {
  test('lands on the most recent surviving task', () => {
    const survivor = { ...createProject('/repos/survivor'), id: 'survivor' }
    const older = {
      ...createSession(survivor.id, 'codex', 'local'),
      id: 'older',
      updated_at: 100,
    }
    const newer = {
      ...createSession(survivor.id, 'claude', 'local'),
      id: 'newer',
      updated_at: 200,
    }

    // Newest first, so an implementation reading the last entry would fail this.
    expect(projectRemovalDestination([survivor], [newer, older])).toEqual({
      kind: 'session',
      sessionId: 'newer',
    })
  })

  test('opens a fresh task in a surviving project when no task is left', () => {
    const survivor = { ...createProject('/repos/survivor'), id: 'survivor' }
    expect(projectRemovalDestination([survivor], [])).toEqual({
      kind: 'newTask',
      project: survivor,
    })
  })

  test('skips the projectless scratch project when choosing where to land', () => {
    const scratch = {
      ...createProject('/home/user/.shidou/projects/old-task'),
      id: 'projectless',
      name: 'No project',
    }
    expect(projectRemovalDestination([scratch], [])).toEqual({ kind: 'none' })
  })

  test('falls back to onboarding when nothing survived', () => {
    expect(projectRemovalDestination([], [])).toEqual({ kind: 'none' })
  })
})

function memoryStorage(initial?: string) {
  const values = new Map<string, string>()
  if (initial !== undefined) values.set('shidou.navigation', initial)
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value) },
  }
}

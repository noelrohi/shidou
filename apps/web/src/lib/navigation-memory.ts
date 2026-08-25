import type { AgentSession, Project } from '@shidou/client'
import { isProjectlessProject } from './project-presentation'

export type RememberedNavigation =
  | { kind: 'newTask'; projectId?: string }
  | { kind: 'session'; sessionId: string }

export type RouteDestinationTransition = 'newTask' | 'session' | null

export type TaskRemovalDestination =
  | { kind: 'session'; sessionId: string }
  | { kind: 'newTask'; project: Project }
  | { kind: 'projectless' }
  | { kind: 'none' }

export type ProjectRemovalDestination =
  | { kind: 'session'; sessionId: string }
  | { kind: 'newTask'; project: Project }
  | { kind: 'none' }

interface NavigationStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

const STORAGE_KEY = 'shidou.navigation'

export function routeDestinationTransition(
  previousSessionId: string | undefined,
  sessionId: string | undefined,
  newTaskMode: boolean,
): RouteDestinationTransition {
  if (previousSessionId === sessionId) return null
  if (sessionId) return 'session'
  return previousSessionId && !newTaskMode ? 'newTask' : null
}

/** Match Desktop's destination after removing the selected task. */
export function taskRemovalDestination(
  previousProjects: Project[],
  nextProjects: Project[],
  nextSessions: AgentSession[],
  removed: AgentSession,
): TaskRemovalDestination {
  const nextSession = nextSessions
    .filter((session) => session.project_id === removed.project_id)
    .sort((left, right) => right.updated_at - left.updated_at)[0]
  if (nextSession) return { kind: 'session', sessionId: nextSession.id }

  const removedProject = previousProjects.find((project) => project.id === removed.project_id)
  if (removedProject && isProjectlessProject(removedProject)) {
    return { kind: 'projectless' }
  }

  const project = nextProjects.find((project) => project.id === removed.project_id)
  return project ? { kind: 'newTask', project } : { kind: 'none' }
}

/**
 * Where the window lands once a removed project and its tasks are gone.
 *
 * Read after the removals, so it only ever sees what survived. Matches
 * Desktop's `project_removal_landing`: the most recent surviving task keeps
 * the landing predictable from the sidebar, and with nothing left at all the
 * caller clears the selection and the window falls back to onboarding.
 */
export function projectRemovalDestination(
  nextProjects: Project[],
  nextSessions: AgentSession[],
): ProjectRemovalDestination {
  const newest = nextSessions.reduce<AgentSession | undefined>(
    (best, session) => (!best || session.updated_at > best.updated_at ? session : best),
    undefined,
  )
  if (newest) return { kind: 'session', sessionId: newest.id }

  // Skips the projectless scratch project for the same reason every other path
  // does: it is bookkeeping for one task, not somewhere to land.
  const project = nextProjects.find((project) => !isProjectlessProject(project))
  return project ? { kind: 'newTask', project } : { kind: 'none' }
}

export function browserNavigationStorage(): NavigationStorage | null {
  if (typeof window === 'undefined') return null
  try {
    return window.localStorage
  } catch {
    return null
  }
}

export function readRememberedNavigation(
  storage: NavigationStorage | null,
  daemonAddress: string,
): RememberedNavigation | null {
  if (!storage) return null
  try {
    const entries = JSON.parse(storage.getItem(STORAGE_KEY) ?? '{}') as Record<string, unknown>
    return parseNavigation(entries[daemonAddress])
  } catch {
    return null
  }
}

export function writeRememberedNavigation(
  storage: NavigationStorage | null,
  daemonAddress: string,
  navigation: RememberedNavigation,
) {
  if (!storage) return
  let entries: Record<string, unknown> = {}
  try {
    const parsed = JSON.parse(storage.getItem(STORAGE_KEY) ?? '{}')
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) entries = parsed
  } catch {
    // Replace malformed navigation state with the current destination.
  }
  entries[daemonAddress] = navigation
  try {
    storage.setItem(STORAGE_KEY, JSON.stringify(entries))
  } catch {
    // Navigation still works when browser storage is unavailable.
  }
}

function parseNavigation(value: unknown): RememberedNavigation | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const navigation = value as Record<string, unknown>
  if (navigation.kind === 'newTask') {
    return {
      kind: 'newTask',
      projectId: typeof navigation.projectId === 'string' ? navigation.projectId : undefined,
    }
  }
  if (navigation.kind === 'session' && typeof navigation.sessionId === 'string') {
    return { kind: 'session', sessionId: navigation.sessionId }
  }
  return null
}

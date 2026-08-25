import type { Project } from '@shidou/client'

export const PROJECTLESS_NAME = 'No project'

export function isProjectlessProject(project: Pick<Project, 'name'>): boolean {
  return project.name === PROJECTLESS_NAME
}

export function projectDisplayName(
  project: Pick<Project, 'name'>,
  projectlessName: string,
): string {
  return isProjectlessProject(project) ? projectlessName : project.name
}

/**
 * Shorten a daemon-host path for display. The browser cannot read the host's
 * home directory, so the shapes macOS and Linux actually produce stand in for
 * it; anything else is left verbatim rather than guessed at.
 */
export function abbreviateHomePath(path: string): string {
  return path
    .replace(/^\/Users\/[^/]+(?=\/|$)/, '~')
    .replace(/^\/home\/[^/]+(?=\/|$)/, '~')
    .replace(/^\/root(?=\/|$)/, '~')
}

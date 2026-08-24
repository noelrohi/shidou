import type { AgentSession, Project } from '@shidou/client'
import { ProviderIcon, ShidouIcon } from '@/components/shidou-icon'
import { displayTitle } from '@/lib/daemon-api'
import { projectDisplayName } from '@/lib/project-presentation'
import { taskSwitcherColumns, taskSwitcherPreview } from '@/lib/task-switcher'
import { cn } from '@/lib/utils'

type Translator = (key: string, params?: Record<string, string | number>) => string

/**
 * The overlay only ever moves the highlight; committing happens once when the
 * held modifier is released (or a card is clicked), so cycling never hydrates
 * intermediate transcripts.
 */
export function TaskSwitcher({
  order,
  highlighted,
  sessions,
  projects,
  t,
  onHighlight,
  onCommit,
}: {
  order: readonly string[]
  highlighted: number
  sessions: readonly AgentSession[]
  projects: readonly Project[]
  t: Translator
  onHighlight: (index: number) => void
  onCommit: (index: number) => void
}) {
  const sessionById = new Map(sessions.map((session) => [session.id, session]))
  const projectById = new Map(projects.map((project) => [project.id, project]))
  const columns = taskSwitcherColumns(order.length)
  return (
    <div
      aria-label={t('sidebar.tasks')}
      aria-modal="true"
      className="fixed inset-0 z-[110] grid place-items-center bg-black/20 px-10 dark:bg-black/35"
      role="dialog"
    >
      <div
        className="max-w-full rounded-[26px] border bg-[var(--raised)] p-2 shadow-[0_24px_80px_rgba(0,0,0,0.3)]"
        role="listbox"
        style={{ display: 'grid', gridTemplateColumns: `repeat(${columns}, minmax(0, 194px))` }}
      >
        {order.map((sessionId, index) => {
          const session = sessionById.get(sessionId)
          if (!session) return null
          const project = projectById.get(session.project_id)
          const projectName = project
            ? projectDisplayName(project, t('project.no_project_name'))
            : t('sidebar.unknown_project')
          const branch = session.workspace?.kind === 'worktree' ? session.workspace.branch : null
          const preview = taskSwitcherPreview(session)
          return (
            <button
              aria-selected={index === highlighted}
              className={cn(
                'flex h-[169px] w-full flex-col rounded-[18px] border border-transparent p-[9px] pb-3.5 text-left outline-none',
                index === highlighted && 'border-input bg-accent',
              )}
              key={sessionId}
              role="option"
              tabIndex={-1}
              type="button"
              onClick={() => onCommit(index)}
              onMouseMove={() => onHighlight(index)}
            >
              <span className="mb-[9px] block h-[119px] w-full overflow-hidden rounded-[10px] bg-[var(--inset)] p-2 text-[10.5px] leading-4 text-[var(--text-tertiary)]">
                {preview}
              </span>
              <span className="flex w-full min-w-0 items-center gap-1.5">
                <ProviderIcon className="size-3.5 shrink-0" provider={session.provider} />
                <span className="min-w-0 flex-1 truncate text-[12.5px] text-foreground">
                  {displayTitle(session)}
                </span>
                <TaskSwitcherStatus status={session.status} />
              </span>
              <span className="mt-0.5 flex w-full min-w-0 items-center gap-1 pl-5 text-[11px] text-[var(--text-tertiary)]">
                <span className="min-w-0 truncate">{branch ? `#${branch}` : projectName}</span>
              </span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

function TaskSwitcherStatus({ status }: { status: AgentSession['status'] }) {
  if (status === 'idle') return null
  if (status === 'working' || status === 'connecting') {
    return <ShidouIcon className="size-3 shrink-0 text-[var(--success)] motion-safe:animate-spin" name="loaderCircle" />
  }
  if (status === 'waiting') {
    return <ShidouIcon className="size-3 shrink-0 text-[var(--warning)]" name="alert" />
  }
  return <ShidouIcon className="size-3 shrink-0 text-destructive" name="x" />
}

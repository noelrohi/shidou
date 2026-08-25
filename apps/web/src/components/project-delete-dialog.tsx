import type { Project } from '@shidou/client'
import { ConfirmDialog, ConfirmDialogDetails } from '@/components/confirm-dialog'
import { useI18n } from '@/lib/i18n'
import { abbreviateHomePath, projectDisplayName } from '@/lib/project-presentation'

/**
 * Modal confirmation for removing a project from the sidebar.
 *
 * A project carries its whole task history: transcripts, saved state, and the
 * checkpoint refs each task wrote into the checkout. One menu click is a very
 * small gesture for that much, so it lands here first. No working-tree file is
 * touched — the only thing removed from the checkout is the Git refs Shidou
 * wrote there itself.
 */
export function ProjectDeleteDialog({
  project,
  startedTaskCount,
  onConfirm,
  onOpenChange,
}: {
  project: Project | null
  startedTaskCount: number
  onConfirm: (projectId: string) => Promise<void>
  onOpenChange: (open: boolean) => void
}) {
  const { t } = useI18n()
  if (!project) return null

  const name = projectDisplayName(project, t('project.no_project_name'))
  const taskCountLine = startedTaskCount === 0
    ? null
    : startedTaskCount === 1
      ? t('project.remove_one_task')
      : t('project.remove_many_tasks', { count: startedTaskCount })

  return (
    <ConfirmDialog
      open
      // A project with nothing in it loses nothing but itself, so the body must
      // not claim saved tasks and checkpoints are going with it.
      body={t(startedTaskCount === 0 ? 'project.remove_body_empty' : 'project.remove_body')}
      confirmLabel={t('common.remove')}
      title={t('project.remove_title', { name })}
      onConfirm={() => onConfirm(project.id)}
      onOpenChange={onOpenChange}
    >
      {/* The folder and the task count read as a short list of what is at
          stake, matching the task removal copy rather than a filled panel. */}
      <ConfirmDialogDetails
        lines={[abbreviateHomePath(project.path), taskCountLine]
          .filter((line): line is string => Boolean(line))}
      />
    </ConfirmDialog>
  )
}

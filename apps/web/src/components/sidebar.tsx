import type { AgentSession, Project } from '@waku/client'
import { ContextMenu } from '@base-ui/react/context-menu'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Virtuoso } from 'react-virtuoso'
import { Button } from '@/components/ui/button'
import { ControlMenu } from '@/components/control-menu'
import { Input } from '@/components/ui/input'
import { PanelResizeHandle } from '@/components/panel-resize-handle'
import { WakuIcon } from '@/components/waku-icon'
import { useWorkspaceBranches } from '@/hooks/use-daemon-data'
import { displayTitle, type TaskState } from '@/lib/daemon-api'
import { useDaemon } from '@/lib/daemon-context'
import { useI18n } from '@/lib/i18n'
import {
  nextSidebarUpdateDelay,
  sessionTimeLabel,
  sidebarGroups,
  sidebarRows,
  PROJECT_REVEAL_BATCH,
  type DateGroup,
  type SessionItem,
  type SidebarGrouping,
  type SidebarOrdering,
} from '@/lib/sidebar-presentation'
import { cn } from '@/lib/utils'
import wakuAppIconUrl from '../../../../website/public/app-icon.png'

interface SidebarProps {
  taskState: TaskState
  selectedSessionId?: string
  mobileOpen: boolean
  width: number
  collapseGroupsSignal?: number
  onMobileOpenChange: (open: boolean) => void
  onToggleSidebar: () => void
  onWidthChange: (width: number) => void
  onNewTask: () => void
  onNewTaskInProject?: (project: Project) => void
  onNewProjectlessTask?: () => void
  onAddProject: () => void
  onSelectSession: (sessionId: string) => void
  onRenameSession: (sessionId: string, title: string) => Promise<void>
  onRemoveSession: (sessionId: string) => Promise<void>
  onSearch: () => void
  onSettings: () => void
}

const GROUP_TRANSLATION_KEYS: Record<DateGroup, string> = {
  today: 'sidebar.today',
  yesterday: 'sidebar.yesterday',
  week: 'sidebar.this_week',
  month: 'sidebar.this_month',
  year: 'sidebar.this_year',
  more: 'sidebar.more',
}

type Translator = (key: string, params?: Record<string, string | number>) => string

export function Sidebar({
  taskState,
  selectedSessionId,
  mobileOpen,
  width,
  collapseGroupsSignal = 0,
  onMobileOpenChange,
  onToggleSidebar,
  onWidthChange,
  onNewTask,
  onNewTaskInProject,
  onNewProjectlessTask,
  onAddProject,
  onSelectSession,
  onRenameSession,
  onRemoveSession,
  onSearch,
  onSettings,
}: SidebarProps) {
  const { t } = useI18n()
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [grouping, setGrouping] = useState<SidebarGrouping>(() => readStoredChoice('waku.sidebarGrouping', 'updated', ['updated', 'project']))
  const [ordering, setOrdering] = useState<SidebarOrdering>(() => readStoredChoice('waku.sidebarOrdering', 'newest', ['newest', 'oldest']))
  const [revealed, setRevealed] = useState<ReadonlyMap<string, number>>(new Map())
  const [liveWidth, setLiveWidth] = useState(width)
  const [nowSeconds, setNowSeconds] = useState(() => Math.floor(Date.now() / 1_000))
  const groups = sidebarGroups(taskState.projects, taskState.sessions, {
    grouping,
    ordering,
    now: new Date(nowSeconds * 1_000),
    revealed,
    unknownProject: t('sidebar.unknown_project'),
    projectlessName: t('project.no_project_name'),
  })
  const rows = sidebarRows(groups, collapsed)
  const groupKeys = useRef<string[]>([])
  useEffect(() => {
    groupKeys.current = groups.map((group) => group.key)
  })

  function chooseGrouping(next: SidebarGrouping) {
    setGrouping(next)
    storeChoice('waku.sidebarGrouping', next)
  }

  function chooseOrdering(next: SidebarOrdering) {
    setOrdering(next)
    storeChoice('waku.sidebarOrdering', next)
  }

  function toggleGroup(key: string, force?: boolean) {
    setCollapsed((current) => {
      const next = new Set(current)
      const collapse = force ?? !next.has(key)
      if (collapse) next.add(key)
      else next.delete(key)
      return next
    })
  }

  useEffect(() => setLiveWidth(width), [width])
  useEffect(() => {
    if (!collapseGroupsSignal) return
    setCollapsed(new Set(groupKeys.current))
    setRevealed(new Map())
  }, [collapseGroupsSignal])
  useEffect(() => {
    const delay = nextSidebarUpdateDelay(taskState.sessions, nowSeconds)
    const timer = window.setTimeout(
      () => setNowSeconds(Math.floor(Date.now() / 1_000)),
      delay * 1_000,
    )
    return () => window.clearTimeout(timer)
  }, [nowSeconds, taskState.sessions])

  return (
    <>
      <button
        aria-label={t('sidebar.close')}
        aria-hidden={!mobileOpen}
        className={cn(
          'pointer-events-none fixed inset-0 z-30 bg-black/25 opacity-0 transition-opacity motion-reduce:transition-none lg:hidden',
          mobileOpen && 'pointer-events-auto opacity-100',
        )}
        tabIndex={mobileOpen ? 0 : -1}
        type="button"
        onClick={() => onMobileOpenChange(false)}
      />
      <aside
        className={cn(
          'pointer-events-none invisible fixed inset-y-0 left-0 z-40 flex shrink-0 -translate-x-full flex-col border-r border-sidebar-border bg-sidebar text-sidebar-foreground transition-transform motion-reduce:transition-none lg:pointer-events-auto lg:visible lg:relative lg:z-auto lg:translate-x-0',
          mobileOpen && 'pointer-events-auto visible translate-x-0',
        )}
        style={{ width: `min(${liveWidth}px, 92vw)` }}
      >
        <header className="flex h-12 shrink-0 items-center px-2.5">
          <img
            alt="Pagesmith"
            className="size-6 rounded-md"
            draggable={false}
            src={wakuAppIconUrl}
          />
          <div className="flex-1" />
          <Button
            aria-label={t('sidebar.hide')}
            size="icon-sm"
            variant="ghost"
            onClick={onToggleSidebar}
          >
            <WakuIcon name="panelLeft" />
          </Button>
        </header>
        <div className="px-2.5">
          <SidebarAction
            icon={<WakuIcon name="pencil" />}
            label={t('menu.new_task')}
            onClick={() => {
              onNewTask()
              onMobileOpenChange(false)
            }}
          />
        </div>

        <nav aria-label={t('sidebar.tasks')} className="min-h-0 flex-1">
          <Virtuoso
            className="size-full"
            computeItemKey={(_, row) => row.key}
            data={rows}
            defaultItemHeight={52}
            increaseViewportBy={200}
            itemContent={(_, row) => {
              if (row.kind === 'search') {
                return (
                  <div className="h-[42px] px-2.5">
                    <SidebarAction
                      icon={<WakuIcon name="search" />}
                      label={t('sidebar.search')}
                      onClick={onSearch}
                    />
                  </div>
                )
              }
              if (row.kind === 'spacer') return <div className="h-2.5" />
              if (row.kind === 'group') {
                const folder = row.group.kind !== 'date'
                const label = row.group.kind === 'date'
                  ? t(GROUP_TRANSLATION_KEYS[row.group.dateId!])
                  : row.group.label
                const compose = folder
                  ? row.group.kind === 'projectless'
                    ? onNewProjectlessTask
                    : row.group.project && onNewTaskInProject
                      ? () => onNewTaskInProject(row.group.project!)
                      : undefined
                  : undefined
                return (
                  <div className="px-2.5">
                    <div className="group/header relative flex h-7 items-center justify-between px-2">
                      <button
                        aria-expanded={!row.collapsed}
                        className={cn(
                          'group flex h-[22px] min-w-0 items-center gap-[5px] rounded px-1 text-[12.5px] font-medium text-[var(--text-tertiary)] outline-none hover:text-foreground focus-visible:ring-1 focus-visible:ring-ring',
                          folder && 'text-[var(--text-secondary)]',
                        )}
                        type="button"
                        onClick={() => toggleGroup(row.group.key)}
                        onKeyDown={(event) => {
                          if (event.key === 'ArrowLeft' && !row.collapsed) {
                            event.preventDefault()
                            toggleGroup(row.group.key, true)
                          } else if (event.key === 'ArrowRight' && row.collapsed) {
                            event.preventDefault()
                            toggleGroup(row.group.key, false)
                          }
                        }}
                      >
                        {folder && <WakuIcon className="size-3.5 shrink-0" name="folder" />}
                        <span className="min-w-0 truncate">{label}</span>
                        <WakuIcon
                          className="size-3 shrink-0 opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100"
                          name={row.collapsed ? 'chevronRight' : 'chevronDown'}
                        />
                      </button>
                      <span className="flex shrink-0 items-center">
                        {compose && (
                          <Button
                            aria-label={t('menu.new_task')}
                            className="text-[var(--text-tertiary)] opacity-0 focus-visible:opacity-100 group-hover/header:opacity-100"
                            size="icon-sm"
                            variant="ghost"
                            onClick={() => {
                              compose()
                              onMobileOpenChange(false)
                            }}
                          >
                            <WakuIcon name="pencil" />
                          </Button>
                        )}
                        {row.first && (
                          <>
                            <SidebarOptionsMenu
                              grouping={grouping}
                              ordering={ordering}
                              t={t}
                              onGrouping={chooseGrouping}
                              onOrdering={chooseOrdering}
                            />
                            <Button
                              aria-label={t('sidebar.add_project')}
                              className="text-[var(--text-tertiary)]"
                              size="icon-sm"
                              variant="ghost"
                              onClick={onAddProject}
                            >
                              <WakuIcon name="folderNew" />
                            </Button>
                          </>
                        )}
                      </span>
                      {folder && !row.collapsed && row.group.sessions.length > 0 && (
                        <span aria-hidden className="absolute -bottom-0.5 left-[15px] top-[19px] w-px bg-border" />
                      )}
                    </div>
                  </div>
                )
              }
              if (row.kind === 'showMore') {
                return (
                  <div className="px-2.5">
                    <div className="relative flex h-[30px] items-center pl-7">
                      <span
                        aria-hidden
                        className="absolute left-[15px] top-0 h-[15px] w-[9px] rounded-bl border-b border-l border-border"
                      />
                      <button
                        className="rounded px-1 text-[12px] text-[var(--text-tertiary)] outline-none hover:text-foreground focus-visible:ring-1 focus-visible:ring-ring"
                        type="button"
                        onClick={() => setRevealed((current) => {
                          const next = new Map(current)
                          next.set(row.group.key, (next.get(row.group.key) ?? 0) + PROJECT_REVEAL_BATCH)
                          return next
                        })}
                      >
                        {t('sidebar.show_more')}
                      </button>
                    </div>
                  </div>
                )
              }
              return (
                <div className="relative px-2.5 pb-px">
                  {row.guides && (
                    <span aria-hidden className="absolute bottom-0 left-[25px] top-0 w-px bg-border" />
                  )}
                  <div className={cn(row.guides && 'pl-[18px]')}>
                  <SessionRow
                    guides={row.guides}
                    item={row.item}
                    nowSeconds={nowSeconds}
                    selected={selectedSessionId === row.item.session.id}
                    t={t}
                    onRemove={onRemoveSession}
                    onRename={onRenameSession}
                    onSelect={(sessionId) => {
                      onSelectSession(sessionId)
                      onMobileOpenChange(false)
                    }}
                  />
                  </div>
                </div>
              )
            }}
          />
        </nav>

        <div className="flex h-10 shrink-0 items-center px-2.5">
          <Button
            aria-label={t('common.settings')}
            className="text-[var(--text-tertiary)]"
            size="icon-sm"
            variant="ghost"
            onClick={onSettings}
          >
            <WakuIcon name="settings" />
          </Button>
          <div className="flex-1" />
          <ConnectionDot />
        </div>
        <PanelResizeHandle
          className="hidden lg:block"
          edge="right"
          label={t('sidebar.resize')}
          max={420}
          min={180}
          value={liveWidth}
          onChange={setLiveWidth}
          onCommit={onWidthChange}
        />
      </aside>

    </>
  )
}

function SidebarAction({
  icon,
  label,
  onClick,
}: {
  icon: ReactNode
  label: string
  onClick: () => void
}) {
  return (
    <button
      className="flex h-8 w-full items-center gap-2.5 rounded-[7px] px-1 text-left text-[13px] text-[var(--text-secondary)] outline-none hover:bg-sidebar-accent focus-visible:ring-1 focus-visible:ring-ring active:bg-sidebar-accent"
      type="button"
      onClick={onClick}
    >
      <span className="grid size-5 place-items-center [&>svg]:size-4">{icon}</span>
      <span className="truncate">{label}</span>
    </button>
  )
}

function SessionRow({
  item,
  guides = false,
  nowSeconds,
  selected,
  onSelect,
  onRename,
  onRemove,
  t,
}: {
  item: SessionItem
  guides?: boolean
  nowSeconds: number
  selected: boolean
  onSelect: (sessionId: string) => void
  onRename: (sessionId: string, title: string) => Promise<void>
  onRemove: (sessionId: string) => Promise<void>
  t: Translator
}) {
  const [menuOpen, setMenuOpen] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [title, setTitle] = useState(displayTitle(item.session))
  const skipRenameCommit = useRef(false)
  const rowButton = useRef<HTMLButtonElement>(null)
  const restoreMenuFocus = useRef(false)
  const currentTitle = displayTitle(item.session)

  async function commitRename() {
    if (skipRenameCommit.current) {
      skipRenameCommit.current = false
      return
    }
    const next = title.trim()
    setRenaming(false)
    if (!next || next === currentTitle) {
      setTitle(currentTitle)
      return
    }
    try {
      await onRename(item.session.id, next)
    } catch {
      setTitle(currentTitle)
    }
  }

  useEffect(() => {
    if (!renaming) setTitle(currentTitle)
  }, [currentTitle, renaming])

  return (
    <ContextMenu.Root
      open={menuOpen}
      onOpenChange={(open) => {
        setMenuOpen(renaming ? false : open)
        if (!open && restoreMenuFocus.current) {
          restoreMenuFocus.current = false
          requestAnimationFrame(() => rowButton.current?.focus())
        }
      }}
    >
      <ContextMenu.Trigger
        className={cn(
          'group relative rounded-[7px] hover:bg-sidebar-accent',
          selected && 'bg-sidebar-accent',
        )}
      >
        {renaming ? (
          <div className="flex h-[51px] w-full min-w-0 flex-col gap-1 rounded-[7px] px-2 py-[7px]">
            <span className="flex min-w-0 w-full items-center gap-1.5 leading-[18px]">
              <Input
                autoFocus
                className="h-[22px] min-w-0 flex-1 rounded border-ring bg-[var(--inset)] px-1 text-[13.5px]"
                value={title}
                onBlur={() => void commitRename()}
                onChange={(event) => setTitle(event.target.value)}
                onClick={(event) => event.stopPropagation()}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    event.preventDefault()
                    event.currentTarget.blur()
                  }
                  if (event.key === 'Escape') {
                    event.preventDefault()
                    skipRenameCommit.current = true
                    setTitle(currentTitle)
                    setRenaming(false)
                  }
                }}
              />
              <SessionStatus status={item.session.status} t={t} />
            </span>
            <SessionMetadata guides={guides} item={item} nowSeconds={nowSeconds} t={t} />
          </div>
        ) : (
          <button
            aria-current={selected ? 'page' : undefined}
            aria-haspopup="menu"
            className="flex h-[51px] w-full min-w-0 flex-col gap-1 rounded-[7px] px-2 py-[7px] text-left outline-none focus-visible:ring-1 focus-visible:ring-ring"
            ref={rowButton}
            type="button"
            onClick={() => onSelect(item.session.id)}
            onKeyDown={(event) => {
              if ((event.shiftKey && event.key === 'F10') || event.key === 'ContextMenu') {
                event.preventDefault()
                restoreMenuFocus.current = true
                setMenuOpen(true)
              }
            }}
          >
            <span className="flex min-w-0 w-full items-center gap-1.5 leading-[18px]">
              <span className="min-w-0 flex-1 truncate text-[13.5px] text-foreground">
                {currentTitle}
              </span>
              <SessionStatus status={item.session.status} t={t} />
            </span>
            <SessionMetadata guides={guides} item={item} nowSeconds={nowSeconds} t={t} />
          </button>
        )}
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner className="z-[100] outline-none">
          <ContextMenu.Popup
            className="waku-menu-surface"
            finalFocus={false}
          >
            <ContextMenu.Item
              className="waku-menu-item"
              onClick={() => {
                restoreMenuFocus.current = false
                setMenuOpen(false)
                skipRenameCommit.current = false
                setTitle(currentTitle)
                setRenaming(true)
              }}
            >
              <WakuIcon className="size-3" name="pencil" /> {t('common.rename')}
            </ContextMenu.Item>
            <ContextMenu.Separator className="waku-menu-separator" />
            <ContextMenu.Item
              className="waku-menu-item text-destructive data-[highlighted]:bg-[var(--danger-soft)]"
              onClick={() => {
                restoreMenuFocus.current = false
                setMenuOpen(false)
                void onRemove(item.session.id).catch(() => {})
              }}
            >
              <WakuIcon className="size-3" name="trash" /> {t('common.remove')}
            </ContextMenu.Item>
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}

function SessionMetadata({
  item,
  guides = false,
  nowSeconds,
  t,
}: {
  item: SessionItem
  guides?: boolean
  nowSeconds: number
  t: Translator
}) {
  const timeLabel = sessionTimeLabel(item.session, nowSeconds, t)
  return (
    <span className="flex w-full min-w-0 items-center gap-1.5 text-[11.5px] leading-[15px] text-[var(--text-tertiary)]">
      {guides ? (
        item.branch ? (
          <BranchLabel branch={item.branch} />
        ) : (item.session.workspace ?? { kind: 'local' }).kind === 'local' && item.projectPath ? (
          <ProjectBranchLabel path={item.projectPath} />
        ) : (
          <span className="min-w-0 flex-1" />
        )
      ) : (
        <>
          <WakuIcon className="size-[11px] shrink-0" name="folder" />
          <span className="min-w-0 flex-1 truncate">{item.projectName}</span>
        </>
      )}
      {timeLabel && (
        <span className={cn(
          'shrink-0 text-[var(--text-ghost)]',
          item.session.status !== 'idle' && 'text-[var(--text-tertiary)]',
        )}>
          {timeLabel}
        </span>
      )}
    </span>
  )
}

function SessionStatus({ status, t }: { status: AgentSession['status']; t: Translator }) {
  if (status === 'idle') return null
  if (status === 'working' || status === 'connecting') {
    return <WakuIcon label={t('sidebar.status_working')} className="size-3 text-[var(--success)] motion-safe:animate-spin" name="loaderCircle" />
  }
  if (status === 'waiting') {
    return <WakuIcon label={t('sidebar.status_waiting')} className="size-3 text-[var(--warning)]" name="alert" />
  }
  return <WakuIcon label={t('sidebar.status_failed')} className="size-3 text-destructive" name="x" />
}

function BranchLabel({ branch }: { branch: string }) {
  return (
    <>
      <WakuIcon className="size-[11px] shrink-0" name="gitBranch" />
      <span className="min-w-0 flex-1 truncate">{branch}</span>
    </>
  )
}

function ProjectBranchLabel({ path }: { path: string }) {
  const branches = useWorkspaceBranches(path)
  const current = branches.data?.current ?? branches.data?.detached_head ?? null
  if (!current) return <span className="min-w-0 flex-1" />
  return <BranchLabel branch={current} />
}

function ConnectionDot() {
  const { t } = useI18n()
  const { phase } = useDaemon()
  return (
    <span
      aria-label={`${t('settings.daemon')} · ${t(`daemon.phase_${phase}`)}`}
      className={cn(
        'block size-1.5 rounded-full bg-[var(--text-ghost)]',
        phase === 'connected' && 'bg-[var(--success)]',
        phase === 'error' && 'bg-destructive',
      )}
      role="img"
    />
  )
}

function SidebarOptionsMenu({
  grouping,
  ordering,
  t,
  onGrouping,
  onOrdering,
}: {
  grouping: SidebarGrouping
  ordering: SidebarOrdering
  t: Translator
  onGrouping: (grouping: SidebarGrouping) => void
  onOrdering: (ordering: SidebarOrdering) => void
}) {
  return (
    <ControlMenu
      caret={false}
      highlightTriggerWhenOpen
      items={[
        {
          id: 'grouping-project',
          section: t('sidebar.grouping'),
          label: t('sidebar.grouping_project'),
          selected: grouping === 'project',
          onSelect: () => onGrouping('project'),
        },
        {
          id: 'grouping-updated',
          section: t('sidebar.grouping'),
          label: t('sidebar.grouping_updated'),
          selected: grouping === 'updated',
          onSelect: () => onGrouping('updated'),
        },
        {
          id: 'ordering-newest',
          section: t('sidebar.ordering'),
          label: t('sidebar.ordering_newest'),
          selected: ordering === 'newest',
          separatorBefore: true,
          onSelect: () => onOrdering('newest'),
        },
        {
          id: 'ordering-oldest',
          section: t('sidebar.ordering'),
          label: t('sidebar.ordering_oldest'),
          selected: ordering === 'oldest',
          onSelect: () => onOrdering('oldest'),
        },
      ]}
      label={t('sidebar.options')}
      placement="below"
      triggerClassName="size-7 justify-center px-0 text-[var(--text-tertiary)]"
    >
      <WakuIcon className="size-3.5" name="listFilter" />
    </ControlMenu>
  )
}

function readStoredChoice<Choice extends string>(
  key: string,
  fallback: Choice,
  choices: readonly Choice[],
): Choice {
  if (typeof window === 'undefined') return fallback
  const stored = window.localStorage.getItem(key)
  return choices.includes(stored as Choice) ? stored as Choice : fallback
}

function storeChoice(key: string, value: string) {
  if (typeof window === 'undefined') return
  window.localStorage.setItem(key, value)
}

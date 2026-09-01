import type { AgentSession, Project } from '@shidou/client'
import { ContextMenu } from '@base-ui/react/context-menu'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Virtuoso } from 'react-virtuoso'
import { Button } from '@/components/ui/button'
import { ControlMenu } from '@/components/control-menu'
import { Input } from '@/components/ui/input'
import { PanelResizeHandle } from '@/components/panel-resize-handle'
import { ShidouIcon } from '@/components/shidou-icon'
import { useWorkspaceBranches } from '@/hooks/use-daemon-data'
import { SHIDOU_APP_ICON_URL } from '@/lib/branding'
import { displayTitle, type TaskState } from '@/lib/daemon-api'
import { useDaemon } from '@/lib/daemon-context'
import { useI18n } from '@/lib/i18n'
import {
  nextSidebarUpdateDelay,
  sessionTimeLabel,
  sidebarGroups,
  sidebarRows,
  PROJECT_REVEAL_BATCH,
  SHELF_GROUP_KEY,
  type DateGroup,
  type SessionGroup,
  type SessionItem,
  type SidebarGrouping,
  type SidebarOrdering,
} from '@/lib/sidebar-presentation'
import { cn } from '@/lib/utils'

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
  onHerdr: () => void
  onSelectSession: (sessionId: string) => void
  onRenameSession: (sessionId: string, title: string) => Promise<void>
  onRemoveSession: (sessionId: string) => Promise<void>
  onArchiveSession: (sessionId: string, archived: boolean) => Promise<void>
  onRemoveProject?: (project: Project) => void
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
  onArchiveSession,
  onRemoveProject,
  onHerdr,
  onSearch,
  onSettings,
}: SidebarProps) {
  const { t } = useI18n()
  // The Task Shelf opens on demand. Like every other fold here it is
  // runtime-only — this sidebar persists grouping and ordering, not disclosure.
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set([SHELF_GROUP_KEY]))
  const [grouping, setGrouping] = useState<SidebarGrouping>(() => readStoredChoice('shidou.sidebarGrouping', 'updated', ['updated', 'project']))
  const [ordering, setOrdering] = useState<SidebarOrdering>(() => readStoredChoice('shidou.sidebarOrdering', 'newest', ['newest', 'oldest']))
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
    shelfLabel: (count) => t('sidebar.task_shelf', { count }),
  })
  const rows = sidebarRows(groups, collapsed)
  const groupKeys = useRef<string[]>([])
  useEffect(() => {
    groupKeys.current = groups.map((group) => group.key)
  })
  // Unlike a project's, the projectless key is reused: the section is
  // bookkeeping for the one task inside it, and the next scratch task rebuilds
  // it under the same key. Its runtime-only state has to go with it, or that
  // task reappears collapsed and folded under a stale reveal count.
  const hasProjectless = groups.some(
    (group) => group.kind === 'projectless' && group.sessions.length > 0,
  )
  useEffect(() => {
    if (hasProjectless) return
    setCollapsed((current) => {
      if (!current.has('projectless')) return current
      const next = new Set(current)
      next.delete('projectless')
      return next
    })
    setRevealed((current) => {
      if (!current.has('projectless')) return current
      const next = new Map(current)
      next.delete('projectless')
      return next
    })
  }, [hasProjectless])

  function chooseGrouping(next: SidebarGrouping) {
    setGrouping(next)
    storeChoice('shidou.sidebarGrouping', next)
  }

  function chooseOrdering(next: SidebarOrdering) {
    setOrdering(next)
    storeChoice('shidou.sidebarOrdering', next)
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
            alt="Shidou"
            className="size-6 rounded-md"
            draggable={false}
            src={SHIDOU_APP_ICON_URL}
          />
          <div className="flex-1" />
          <Button
            aria-label={t('sidebar.hide')}
            size="icon-sm"
            variant="ghost"
            onClick={onToggleSidebar}
          >
            <ShidouIcon name="panelLeft" />
          </Button>
        </header>
        <div className="px-2.5">
          <SidebarAction
            icon={<ShidouIcon name="pencil" />}
            label={t('menu.new_task')}
            onClick={() => {
              onNewTask()
              onMobileOpenChange(false)
            }}
          />
          <SidebarAction
            icon={<ShidouIcon name="terminal" />}
            label="Herdr"
            onClick={() => {
              onHerdr()
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
                      icon={<ShidouIcon name="search" />}
                      label={t('sidebar.search')}
                      onClick={onSearch}
                    />
                  </div>
                )
              }
              if (row.kind === 'spacer') return <div className="h-2.5" />
              if (row.kind === 'group') {
                const folder = row.group.kind === 'project' || row.group.kind === 'projectless'
                const compose = folder
                  ? row.group.kind === 'projectless'
                    ? onNewProjectlessTask
                    : row.group.project && onNewTaskInProject
                      ? () => onNewTaskInProject(row.group.project!)
                      : undefined
                  : undefined
                return (
                  <GroupRow
                    collapsed={row.collapsed}
                    first={row.first}
                    group={row.group}
                    grouping={grouping}
                    ordering={ordering}
                    t={t}
                    onAddProject={onAddProject}
                    onCompose={compose && (() => {
                      compose()
                      onMobileOpenChange(false)
                    })}
                    onGrouping={chooseGrouping}
                    onOrdering={chooseOrdering}
                    onRemoveProject={onRemoveProject}
                    onToggle={toggleGroup}
                  />
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
                    onArchive={onArchiveSession}
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
            <ShidouIcon name="settings" />
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

/**
 * One collapsible sidebar section header.
 *
 * An ordinary project gains a context menu — mouse, Shift+F10, and the primary
 * modifier with Backspace — whose removal path is gated behind a confirmation.
 * Date groups are derived from timestamps and the projectless section is pruned
 * with the task inside it, so neither offers removal.
 */
function GroupRow({
  group,
  collapsed,
  first,
  grouping,
  ordering,
  t,
  onToggle,
  onCompose,
  onAddProject,
  onGrouping,
  onOrdering,
  onRemoveProject,
}: {
  group: SessionGroup
  collapsed: boolean
  first: boolean
  grouping: SidebarGrouping
  ordering: SidebarOrdering
  t: Translator
  onToggle: (key: string, force?: boolean) => void
  onCompose?: () => void
  onAddProject: () => void
  onGrouping: (grouping: SidebarGrouping) => void
  onOrdering: (ordering: SidebarOrdering) => void
  onRemoveProject?: (project: Project) => void
}) {
  const [menuOpen, setMenuOpen] = useState(false)
  const headerButton = useRef<HTMLButtonElement>(null)
  const restoreMenuFocus = useRef(false)
  const folder = group.kind === 'project' || group.kind === 'projectless'
  // The shelf starts collapsed, so the only affordance saying the row opens
  // must not wait for the pointer to arrive.
  const shelf = group.kind === 'shelf'
  const removable = group.kind === 'project' && group.project && onRemoveProject
    ? group.project
    : undefined
  const label = group.kind === 'date' ? t(GROUP_TRANSLATION_KEYS[group.dateId!]) : group.label

  const header = (
    <div className="group/header relative flex h-7 items-center justify-between px-2">
      <button
        aria-expanded={!collapsed}
        aria-haspopup={removable ? 'menu' : undefined}
        className={cn(
          'group flex h-[22px] min-w-0 items-center gap-[5px] rounded px-1 text-[12.5px] font-medium text-[var(--text-tertiary)] outline-none hover:text-foreground focus-visible:ring-1 focus-visible:ring-ring',
          folder && 'text-[var(--text-secondary)]',
        )}
        ref={headerButton}
        type="button"
        onClick={() => onToggle(group.key)}
        onKeyDown={(event) => {
          if (event.key === 'ArrowLeft' && !collapsed) {
            event.preventDefault()
            onToggle(group.key, true)
            return
          }
          if (event.key === 'ArrowRight' && collapsed) {
            event.preventDefault()
            onToggle(group.key, false)
            return
          }
          // The same two gestures the task rows offer, so a project is never
          // mouse-only. Nothing is behind them on a group without a menu.
          if (!removable) return
          if ((event.shiftKey && event.key === 'F10') || event.key === 'ContextMenu') {
            event.preventDefault()
            restoreMenuFocus.current = true
            setMenuOpen(true)
          } else if ((event.metaKey || event.ctrlKey) && event.key === 'Backspace') {
            event.preventDefault()
            onRemoveProject?.(removable)
          }
        }}
      >
        {folder && <ShidouIcon className="size-3.5 shrink-0" name="folder" />}
        <span className="min-w-0 truncate">{label}</span>
        <ShidouIcon
          className={cn(
            'size-3 shrink-0',
            !shelf && 'opacity-0 group-hover:opacity-100 group-focus-visible:opacity-100',
          )}
          name={collapsed ? 'chevronRight' : 'chevronDown'}
        />
      </button>
      <span className="flex shrink-0 items-center">
        {onCompose && (
          <Button
            aria-label={t('menu.new_task')}
            className="text-[var(--text-tertiary)] opacity-0 focus-visible:opacity-100 group-hover/header:opacity-100"
            size="icon-sm"
            variant="ghost"
            onClick={onCompose}
          >
            <ShidouIcon name="pencil" />
          </Button>
        )}
        {first && (
          <>
            <SidebarOptionsMenu
              grouping={grouping}
              ordering={ordering}
              t={t}
              onGrouping={onGrouping}
              onOrdering={onOrdering}
            />
            <Button
              aria-label={t('sidebar.add_project')}
              className="text-[var(--text-tertiary)]"
              size="icon-sm"
              variant="ghost"
              onClick={onAddProject}
            >
              <ShidouIcon name="folderNew" />
            </Button>
          </>
        )}
      </span>
      {folder && !collapsed && group.sessions.length > 0 && (
        <span aria-hidden className="absolute -bottom-0.5 left-[15px] top-[19px] w-px bg-border" />
      )}
    </div>
  )

  if (!removable) return <div className="px-2.5">{header}</div>

  return (
    <div className="px-2.5">
      <ContextMenu.Root
        open={menuOpen}
        onOpenChange={(open) => {
          setMenuOpen(open)
          if (!open && restoreMenuFocus.current) {
            restoreMenuFocus.current = false
            requestAnimationFrame(() => headerButton.current?.focus())
          }
        }}
      >
        <ContextMenu.Trigger>{header}</ContextMenu.Trigger>
        <ContextMenu.Portal>
          <ContextMenu.Positioner className="z-[100] outline-none">
            <ContextMenu.Popup className="shidou-menu-surface" finalFocus={false}>
              {onCompose && (
                <>
                  <ContextMenu.Item
                    className="shidou-menu-item"
                    onClick={() => {
                      restoreMenuFocus.current = false
                      setMenuOpen(false)
                      onCompose()
                    }}
                  >
                    <ShidouIcon className="size-3" name="pencil" /> {t('menu.new_task')}
                  </ContextMenu.Item>
                  <ContextMenu.Separator className="shidou-menu-separator" />
                </>
              )}
              <ContextMenu.Item
                className="shidou-menu-item text-destructive data-[highlighted]:bg-[var(--danger-soft)]"
                onClick={() => {
                  restoreMenuFocus.current = false
                  setMenuOpen(false)
                  onRemoveProject?.(removable)
                }}
              >
                <ShidouIcon className="size-3" name="trash" /> {t('project.remove')}
              </ContextMenu.Item>
            </ContextMenu.Popup>
          </ContextMenu.Positioner>
        </ContextMenu.Portal>
      </ContextMenu.Root>
    </div>
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
  onArchive,
  t,
}: {
  item: SessionItem
  guides?: boolean
  nowSeconds: number
  selected: boolean
  onSelect: (sessionId: string) => void
  onRename: (sessionId: string, title: string) => Promise<void>
  onRemove: (sessionId: string) => Promise<void>
  onArchive: (sessionId: string, archived: boolean) => Promise<void>
  t: Translator
}) {
  const [menuOpen, setMenuOpen] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [title, setTitle] = useState(displayTitle(item.session))
  const skipRenameCommit = useRef(false)
  const rowButton = useRef<HTMLButtonElement>(null)
  const restoreMenuFocus = useRef(false)
  const currentTitle = displayTitle(item.session)
  const archived = item.session.archived_at != null
  // The daemon is the authority and refuses to shelve a Task that is still
  // running or waiting for the user; the row only declines to ask. Bringing a
  // Task back is always allowed, because it can only return it to view.
  const busy = item.session.status === 'working'
    || item.session.status === 'connecting'
    || item.session.status === 'waiting'

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
            className="shidou-menu-surface"
            finalFocus={false}
          >
            <ContextMenu.Item
              className="shidou-menu-item"
              onClick={() => {
                restoreMenuFocus.current = false
                setMenuOpen(false)
                skipRenameCommit.current = false
                setTitle(currentTitle)
                setRenaming(true)
              }}
            >
              <ShidouIcon className="size-3" name="pencil" /> {t('common.rename')}
            </ContextMenu.Item>
            <ContextMenu.Item
              className="shidou-menu-item"
              disabled={!archived && busy}
              onClick={() => {
                restoreMenuFocus.current = false
                setMenuOpen(false)
                void onArchive(item.session.id, !archived).catch(() => {})
              }}
            >
              <ShidouIcon className="size-3" name={archived ? 'arrowUp' : 'package'} />
              {' '}
              {archived ? t('common.unarchive') : t('common.archive')}
            </ContextMenu.Item>
            <ContextMenu.Separator className="shidou-menu-separator" />
            <ContextMenu.Item
              className="shidou-menu-item text-destructive data-[highlighted]:bg-[var(--danger-soft)]"
              onClick={() => {
                restoreMenuFocus.current = false
                setMenuOpen(false)
                void onRemove(item.session.id).catch(() => {})
              }}
            >
              <ShidouIcon className="size-3" name="trash" /> {t('common.remove')}
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
          <ShidouIcon className="size-[11px] shrink-0" name="folder" />
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
    return <ShidouIcon label={t('sidebar.status_working')} className="size-3 text-[var(--success)] motion-safe:animate-spin" name="loaderCircle" />
  }
  if (status === 'waiting') {
    return <ShidouIcon label={t('sidebar.status_waiting')} className="size-3 text-[var(--warning)]" name="alert" />
  }
  return <ShidouIcon label={t('sidebar.status_failed')} className="size-3 text-destructive" name="x" />
}

function BranchLabel({ branch }: { branch: string }) {
  return (
    <>
      <ShidouIcon className="size-[11px] shrink-0" name="gitBranch" />
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
      <ShidouIcon className="size-3.5" name="listFilter" />
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

import { ContextMenu } from '@base-ui/react/context-menu'
import { Dialog as DialogPrimitive } from '@base-ui/react/dialog'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import type { MessageAttachment } from '@shidou/client'
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react'
import { Virtuoso, type VirtuosoHandle } from 'react-virtuoso'
import { toast } from 'sonner'
import { ControlMenu, type ControlMenuItem } from '@/components/control-menu'
import { ShidouIcon } from '@/components/shidou-icon'
import { importDaemonPathAttachments, readAttachmentImage } from '@/lib/attachments'
import { daemonKeys, listComposerFiles } from '@/lib/daemon-api'
import { useDaemon } from '@/lib/daemon-context'
import { useI18n } from '@/lib/i18n'
import type { Translator } from '@/lib/transcript-presentation'
import { cn } from '@/lib/utils'
import {
  ATTACH_VISUAL_SELECTION_EVENT,
  buildVisualRowPlan,
  galleryAttachment,
  type AttachVisualSelectionDetail,
  toggleVisualSelection,
  visualFilesInFolder,
  visualFolder,
  visualFolderChoices,
  visualFolderDisplay,
  visualPlanIndex,
  visualRowContaining,
  VISUAL_LAYOUTS,
  workspacePath,
  type VisualGridKey,
  type VisualLayout,
} from '@/lib/visuals-presentation'

/** One daemon round trip per slice keeps the first screen of a big folder fast. */
const IMPORT_CHUNK = 32

interface GalleryImage {
  relativePath: string
  name: string
  /** `null` while the daemon import is in flight; `missing` when it failed. */
  attachment: MessageAttachment | null | 'missing'
}

export interface VisualsRevealRequest {
  path: string
  token: number
}

export function VisualsPanel({
  sessionId,
  panelWidth,
  workspaceRoot,
  revealRequest,
}: {
  sessionId: string | null
  panelWidth: number
  workspaceRoot?: string
  revealRequest?: VisualsRevealRequest | null
}) {
  const { client, config, phase } = useDaemon()
  const { t } = useI18n()
  const queryClient = useQueryClient()
  const [folder, setFolder] = useState<string | null>(null)
  const [layout, setLayout] = useState<VisualLayout>('compact')
  const [images, setImages] = useState<GalleryImage[]>([])
  const [sizes, setSizes] = useState<Record<string, { width: number, height: number }>>({})
  const [selected, setSelected] = useState<string[]>([])
  const [focused, setFocused] = useState(0)
  const [pendingReveal, setPendingReveal] = useState<string | null>(null)
  const [preview, setPreview] = useState<{ name: string, source: string } | null>(null)
  const gallery = useRef<VirtuosoHandle>(null)

  const files = useQuery({
    queryKey: daemonKeys.composerFiles(config?.address ?? 'disconnected', workspaceRoot ?? 'none'),
    queryFn: () => listComposerFiles(requireClient(client), workspaceRoot!),
    enabled: phase === 'connected' && Boolean(client && config && workspaceRoot),
    placeholderData: keepPreviousData,
  })
  const folders = useMemo(() => visualFolderChoices(files.data ?? []), [files.data])
  const folderFiles = useMemo(
    () => folder === null ? [] : visualFilesInFolder(files.data ?? [], folder),
    [files.data, folder],
  )

  useEffect(() => {
    setFolder(null)
    setImages([])
    setSizes({})
    setSelected([])
    setFocused(0)
  }, [workspaceRoot])

  useEffect(() => {
    if (folder === null || files.data === undefined || folders.includes(folder)) return
    setFolder(null)
    setImages([])
    setSelected([])
  }, [files.data, folder, folders])

  useEffect(() => {
    setSelected([])
    setFocused(0)
    if (!client || !workspaceRoot || folder === null) {
      setImages([])
      return
    }
    // The grid shows a pending card per file immediately; imports land one
    // slice at a time so a large folder never blocks the first rows.
    let active = true
    setImages(folderFiles.map((entry) => ({
      relativePath: entry.path,
      name: fileName(entry.path),
      attachment: null,
    })))
    void (async () => {
      for (let start = 0; start < folderFiles.length; start += IMPORT_CHUNK) {
        const slice = folderFiles.slice(start, start + IMPORT_CHUNK)
        const stored = await importDaemonPathAttachments(
          client,
          slice.map((entry) => workspacePath(workspaceRoot, entry.path)),
        )
        if (!active) return
        setImages((current) => current.map((image, index) => {
          if (index < start || index >= start + slice.length) return image
          const attachment = stored[index - start]
          return {
            ...image,
            attachment: attachment
              ? galleryAttachment(attachment, image.relativePath)
              : 'missing',
          }
        }))
      }
    })().catch((error: unknown) => {
      if (!active) return
      toast.error(t('visuals.load_failed', { error: errorMessage(error) }))
    })
    return () => { active = false }
  }, [client, folder, folderFiles, t, workspaceRoot])

  const visible = useMemo(
    () => images.filter((image) => image.attachment !== 'missing'),
    [images],
  )
  const plan = useMemo(
    () => buildVisualRowPlan(
      visible.length,
      (index) => sizes[visible[index]?.relativePath ?? ''],
      layout,
      panelWidth,
    ),
    [layout, panelWidth, sizes, visible],
  )

  // Jump requests from elsewhere in the app (the file editor's "Open in
  // Visuals"): switch to the image's folder, then select, scroll to, and
  // focus its card once the folder's images land.
  useEffect(() => {
    if (!revealRequest) return
    const target = visualFolder(revealRequest.path)
    setFolder((current) => current === target ? current : target)
    setPendingReveal(revealRequest.path)
  }, [revealRequest])

  useEffect(() => {
    if (pendingReveal === null) return
    const index = visible.findIndex((image) => image.relativePath === pendingReveal)
    if (index < 0) return
    const path = pendingReveal
    setPendingReveal(null)
    setSelected((current) => current.includes(path) ? current : [...current, path])
    setFocused(index)
    gallery.current?.scrollIntoView({
      index: Math.max(0, visualRowContaining(plan, index)),
      done: () => window.requestAnimationFrame(() => document.getElementById(cardId(index))?.focus()),
    })
  }, [pendingReveal, plan, visible])

  const selectedAttachments = visible.flatMap((image) => (
    selected.includes(image.relativePath) && image.attachment && image.attachment !== 'missing'
      ? [image.attachment]
      : []
  ))

  function dispatchAttachments(attachments: MessageAttachment[]): number {
    let attached = 0
    const detail: AttachVisualSelectionDetail = {
      sessionId,
      attachments,
      onAttached: (count) => { attached = count },
    }
    window.dispatchEvent(new CustomEvent(ATTACH_VISUAL_SELECTION_EVENT, { detail }))
    return attached
  }

  function attachSelection() {
    if (!selectedAttachments.length) {
      toast.error(t('visuals.select_first'))
      return
    }
    const attached = dispatchAttachments(selectedAttachments)
    if (attached > 0) toast.success(t('visuals.attached', { count: attached }))
  }

  function attachImage(image: GalleryImage) {
    if (!image.attachment || image.attachment === 'missing') return
    if (dispatchAttachments([image.attachment]) > 0) {
      toast.success(t('visuals.image_attached', { name: image.name }))
    }
  }

  async function openPreview(image: GalleryImage) {
    if (!client || !image.attachment || image.attachment === 'missing') return
    try {
      setPreview({
        name: image.name,
        source: await readAttachmentImage(client, image.attachment),
      })
    } catch (error) {
      toast.error(t('visuals.load_failed', { error: errorMessage(error) }))
    }
  }

  function moveFocus(key: VisualGridKey) {
    const next = visualPlanIndex(plan, visible.length, focused, key)
    if (next < 0) return
    setFocused(next)
    gallery.current?.scrollIntoView({
      index: Math.max(0, visualRowContaining(plan, next)),
      done: () => window.requestAnimationFrame(() => document.getElementById(cardId(next))?.focus()),
    })
  }

  function reportSize(path: string, width: number, height: number) {
    if (width <= 0 || height <= 0) return
    setSizes((current) => {
      const known = current[path]
      if (known && known.width === width && known.height === height) return current
      return { ...current, [path]: { width, height } }
    })
  }

  // The chip shows only the folder's own name: deep paths truncate at the
  // tail, which hides exactly the segment that distinguishes them. The
  // dropdown carries the context as an indented tree instead.
  const folderItems: ControlMenuItem[] = folders.map((path) => {
    const { depth, name } = visualFolderDisplay(path)
    return {
      id: path || '.',
      label: name,
      icon: 'folder',
      indent: depth,
      selected: path === folder,
      onSelect: () => setFolder(path),
    }
  })
  const layoutItems: ControlMenuItem[] = VISUAL_LAYOUTS.map((value) => ({
    id: value,
    label: t(`visuals.layout_${value}`),
    selected: value === layout,
    onSelect: () => setLayout(value),
  }))

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      <div className="flex h-[38px] shrink-0 items-center gap-1.5 border-b px-2">
        <ControlMenu
          align="left"
          label={t('visuals.folder')}
          placement="below"
          items={folderItems}
          triggerClassName="h-7 min-w-0 max-w-[55%] px-2 text-[12px]"
        >
          <ShidouIcon className="size-3" name="folder" />
          <span className="truncate">
            {folder === null ? t('visuals.choose_folder') : visualFolderDisplay(folder).name}
          </span>
        </ControlMenu>
        <ControlMenu
          align="right"
          label={t('visuals.layout')}
          placement="below"
          items={layoutItems}
          triggerClassName="h-7 px-2 text-[11px]"
        >
          {t(`visuals.layout_${layout}`)}
        </ControlMenu>
        <span className="min-w-0 flex-1" />
        <ToolbarButton
          icon="rotateCw"
          label={t('visuals.refresh')}
          onClick={() => void queryClient.invalidateQueries({
            queryKey: daemonKeys.composerFiles(config?.address ?? 'disconnected', workspaceRoot ?? 'none'),
          })}
        />
      </div>

      <div className="flex min-h-0 flex-1 flex-col">
        {!workspaceRoot
          ? <EmptyGallery title={t('visuals.no_workspace')} hint={t('visuals.folder_hint')} />
          : files.isLoading
            ? <EmptyGallery loading title={t('visuals.loading')} />
            : folders.length === 0
              ? <EmptyGallery title={t('visuals.no_folders')} hint={t('visuals.folder_hint')} />
              : folder === null
                ? <EmptyGallery title={t('visuals.choose_folder')} hint={t('visuals.folder_hint')} />
                : visible.length === 0
                  ? <EmptyGallery title={t('visuals.no_images')} hint={t('visuals.folder_hint')} />
                  : (
                    <div aria-label={t('visuals.folder')} className="min-h-0 flex-1" role="listbox" aria-multiselectable="true">
                      <Virtuoso
                        className="h-full"
                        ref={gallery}
                        totalCount={plan.length}
                        itemContent={(rowIndex) => {
                          const row = plan[rowIndex]
                          if (!row) return null
                          return (
                            <div
                              className={cn(
                                'flex gap-1.5 px-2',
                                rowIndex === 0 ? 'pt-2' : 'pt-1.5',
                                rowIndex === plan.length - 1 && 'pb-2',
                              )}
                            >
                              {row.widths.map((width, offset) => {
                                const index = row.start + offset
                                const image = visible[index]
                                if (!image) return null
                                return (
                                  <GalleryCard
                                    image={image}
                                    imageHeight={row.imageHeight}
                                    index={index}
                                    key={image.relativePath}
                                    layout={layout}
                                    selected={selected.includes(image.relativePath)}
                                    t={t}
                                    width={width}
                                    onAttach={() => attachImage(image)}
                                    onFocus={() => setFocused(index)}
                                    onMove={moveFocus}
                                    onOpen={() => void openPreview(image)}
                                    onSize={(width, height) => reportSize(image.relativePath, width, height)}
                                    onToggle={() => setSelected((current) => toggleVisualSelection(current, image.relativePath))}
                                  />
                                )
                              })}
                            </div>
                          )
                        }}
                      />
                    </div>
                    )}
      </div>

      <div className="flex min-h-[46px] shrink-0 items-center gap-2 border-t px-2.5">
        <span className="min-w-0 flex-1 text-[11px] text-[var(--text-ghost)]">
          {t('visuals.selected_count', { count: selected.length })}
        </span>
        <button
          className="h-7 rounded-md bg-primary px-2.5 text-[11.5px] font-medium text-primary-foreground outline-none hover:opacity-90 disabled:opacity-40 focus-visible:ring-1 focus-visible:ring-ring"
          disabled={!selectedAttachments.length}
          type="button"
          onClick={attachSelection}
        >
          {t('visuals.attach_selected')}
        </button>
      </div>

      <DialogPrimitive.Root open={Boolean(preview)} onOpenChange={(open) => !open && setPreview(null)}>
        <DialogPrimitive.Portal>
          <DialogPrimitive.Backdrop className="fixed inset-0 z-[110] bg-black/80 transition-opacity data-[ending-style]:opacity-0 data-[starting-style]:opacity-0 motion-reduce:transition-none" />
          <DialogPrimitive.Viewport className="fixed inset-0 z-[110] grid place-items-center overflow-hidden p-9">
            <DialogPrimitive.Popup className="relative flex max-h-full min-h-0 min-w-0 max-w-full flex-col items-center gap-3 outline-none">
              <DialogPrimitive.Title className="sr-only">{preview?.name ?? ''}</DialogPrimitive.Title>
              <DialogPrimitive.Close aria-label={t('attachments.close_preview')} className="absolute -right-[22px] -top-[22px] z-10 grid size-8 place-items-center rounded-full bg-black/50 text-white/90 outline-none hover:bg-black/70 focus-visible:ring-1 focus-visible:ring-white" type="button">
                <ShidouIcon className="size-[13px]" name="x" />
              </DialogPrimitive.Close>
              {preview && <img alt={preview.name} className="block max-h-[calc(100dvh-124px)] max-w-[calc(100dvw-72px)] object-contain" src={preview.source} />}
              <div className="max-w-[560px] truncate rounded-full bg-black/50 px-[11px] py-[5px] text-[11.5px] text-white/90">{preview?.name ?? ''}</div>
            </DialogPrimitive.Popup>
          </DialogPrimitive.Viewport>
        </DialogPrimitive.Portal>
      </DialogPrimitive.Root>
    </div>
  )
}

function GalleryCard({ image, index, layout, width, imageHeight, selected, t, onToggle, onOpen, onAttach, onFocus, onMove, onSize }: {
  image: GalleryImage
  index: number
  layout: VisualLayout
  width: number
  imageHeight: number
  selected: boolean
  t: Translator
  onToggle: () => void
  onOpen: () => void
  onAttach: () => void
  onFocus: () => void
  onMove: (key: VisualGridKey) => void
  onSize: (width: number, height: number) => void
}) {
  const { client } = useDaemon()
  const [source, setSource] = useState<string | null>(null)
  const attachment = image.attachment === 'missing' ? null : image.attachment
  useEffect(() => {
    if (!client || !attachment) {
      setSource(null)
      return
    }
    let live = true
    void readAttachmentImage(client, attachment)
      .then((value) => live && setSource(value))
      .catch(() => live && setSource(null))
    return () => { live = false }
  }, [client, attachment])

  function onKeyDown(event: ReactKeyboardEvent<HTMLDivElement>) {
    if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) {
      event.preventDefault()
      onMove(event.key as VisualGridKey)
    } else if (event.key === ' ') {
      event.preventDefault()
      onToggle()
    } else if (event.key === 'Enter') {
      event.preventDefault()
      onOpen()
    }
  }

  // Ring selection: an accent border offset from the image is the only
  // selected treatment — no fill, no badge. Hover (or keyboard focus within
  // the card) reveals the name scrim and preview button.
  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger
        className="block min-w-0 shrink-0 outline-none"
        style={{ width: `${width + 8}px` }}
      >
        <div
          aria-label={t('visuals.select_image', { name: image.name })}
          aria-selected={selected}
          className={cn(
            'group relative min-w-0 overflow-hidden rounded-lg border-2 p-[2px] text-left outline-none',
            selected ? 'border-primary' : 'border-transparent',
            'focus-visible:border-foreground',
          )}
          id={cardId(index)}
          role="option"
          tabIndex={0}
          title={image.name}
          onClick={onToggle}
          onDoubleClick={onOpen}
          onFocus={onFocus}
          onKeyDown={onKeyDown}
        >
          {source
            ? (
              <img
                alt=""
                className={cn('w-full rounded-[5px]', layout === 'fit' ? 'object-contain' : 'object-cover')}
                draggable={false}
                src={source}
                style={{ height: `${imageHeight}px` }}
                onLoad={(event) => onSize(event.currentTarget.naturalWidth, event.currentTarget.naturalHeight)}
              />
              )
            : (
              <span
                className="grid w-full place-items-center rounded-[5px] bg-[var(--inset)]"
                style={{ height: `${imageHeight}px` }}
              >
                <ShidouIcon className="size-3.5 animate-spin text-[var(--text-ghost)]" name="loaderCircle" />
              </span>
              )}
          <span
            aria-hidden="true"
            className="pointer-events-none absolute inset-x-[2px] bottom-[2px] rounded-b-[5px] bg-gradient-to-b from-transparent to-black/60 px-2 pb-[5px] pt-3.5 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100"
          >
            <span className="block min-w-0 truncate text-[10.5px] text-white/90">{image.name}</span>
          </span>
          {source && (
            <button
              aria-label={t('visuals.preview_image', { name: image.name })}
              className="absolute right-1.5 top-1.5 grid size-6 place-items-center rounded-md bg-[var(--raised)]/80 text-[var(--text-secondary)] opacity-0 outline-none hover:bg-[var(--raised)] group-hover:opacity-100 group-focus-within:opacity-100 focus-visible:opacity-100 focus-visible:ring-1 focus-visible:ring-ring"
              title={t('visuals.preview_image', { name: image.name })}
              type="button"
              onClick={(event) => {
                event.stopPropagation()
                onOpen()
              }}
              onDoubleClick={(event) => event.stopPropagation()}
            >
              <ShidouIcon className="size-[11px]" name="eye" />
            </button>
          )}
        </div>
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner className="z-[100] outline-none">
          <ContextMenu.Popup className="shidou-menu-surface" finalFocus={false}>
            <ContextMenu.Item
              className="shidou-menu-item"
              disabled={!source}
              onClick={onOpen}
            >
              <ShidouIcon className="size-3 text-current" name="eye" />
              {t('visuals.context_preview')}
            </ContextMenu.Item>
            <ContextMenu.Item
              className="shidou-menu-item"
              disabled={!attachment}
              onClick={onAttach}
            >
              <ShidouIcon className="size-3 text-current" name="paperclip" />
              {t('visuals.context_attach')}
            </ContextMenu.Item>
            <ContextMenu.Separator className="shidou-menu-separator" />
            <ContextMenu.Item
              className="shidou-menu-item"
              onClick={() => void navigator.clipboard.writeText(image.relativePath)}
            >
              <ShidouIcon className="size-3 text-current" name="copy" />
              {t('visuals.copy_path')}
            </ContextMenu.Item>
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}

function EmptyGallery({ title, hint, loading = false }: { title: string, hint?: string, loading?: boolean }) {
  return (
    <div className="flex min-h-0 flex-1 items-center justify-center px-7 pb-10 text-center">
      <div className="max-w-64">
        <span className="mx-auto grid size-9 place-items-center rounded-lg border bg-card text-[var(--text-tertiary)]">
          <ShidouIcon className={cn('size-4', loading && 'animate-spin')} name={loading ? 'loaderCircle' : 'folder'} />
        </span>
        <p className="mt-3 text-[12px] text-[var(--text-secondary)]">{title}</p>
        {hint && <p className="mt-1.5 text-[10.5px] leading-4 text-[var(--text-ghost)]">{hint}</p>}
      </div>
    </div>
  )
}

function ToolbarButton({ icon, label, onClick }: { icon: 'rotateCw', label: string, onClick: () => void }) {
  return (
    <button aria-label={label} className="grid size-[26px] shrink-0 place-items-center rounded-[7px] outline-none hover:bg-accent focus-visible:ring-1 focus-visible:ring-ring" title={label} type="button" onClick={onClick}>
      <ShidouIcon className="size-3 text-[var(--text-tertiary)]" name={icon} />
    </button>
  )
}

function cardId(index: number) {
  return `visual-gallery-card-${index}`
}

function fileName(path: string) {
  return path.split(/[\\/]/).at(-1) ?? path
}

function requireClient<T>(client: T | null): T {
  if (!client) throw new Error('The daemon is not connected')
  return client
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error)
}

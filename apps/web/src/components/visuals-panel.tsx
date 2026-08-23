import { Dialog as DialogPrimitive } from '@base-ui/react/dialog'
import { keepPreviousData, useQuery, useQueryClient } from '@tanstack/react-query'
import type { MessageAttachment } from '@waku/client'
import { useEffect, useMemo, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react'
import { Virtuoso } from 'react-virtuoso'
import { toast } from 'sonner'
import { ControlMenu, type ControlMenuItem } from '@/components/control-menu'
import { WakuIcon } from '@/components/waku-icon'
import { importDaemonPathAttachments, readAttachmentImage } from '@/lib/attachments'
import { daemonKeys, listComposerFiles } from '@/lib/daemon-api'
import { useDaemon } from '@/lib/daemon-context'
import { useI18n } from '@/lib/i18n'
import { cn } from '@/lib/utils'
import {
  ATTACH_VISUAL_SELECTION_EVENT,
  galleryAttachment,
  type AttachVisualSelectionDetail,
  toggleVisualSelection,
  visualColumns,
  visualFilesInFolder,
  visualFolders,
  visualGridIndex,
  VISUAL_LAYOUTS,
  workspacePath,
  type VisualGridKey,
  type VisualLayout,
} from '@/lib/visuals-presentation'

interface GalleryImage {
  relativePath: string
  attachment: MessageAttachment | null
}

export function VisualsPanel({
  sessionId,
  panelWidth,
  workspaceRoot,
}: {
  sessionId: string | null
  panelWidth: number
  workspaceRoot?: string
}) {
  const { client, config, phase } = useDaemon()
  const { t } = useI18n()
  const queryClient = useQueryClient()
  const [folder, setFolder] = useState<string | null>(null)
  const [layout, setLayout] = useState<VisualLayout>('compact')
  const [images, setImages] = useState<GalleryImage[]>([])
  const [selected, setSelected] = useState<string[]>([])
  const [focused, setFocused] = useState(0)
  const [preview, setPreview] = useState<{ name: string, source: string } | null>(null)
  const columns = visualColumns(panelWidth, layout)

  const files = useQuery({
    queryKey: daemonKeys.composerFiles(config?.address ?? 'disconnected', workspaceRoot ?? 'none'),
    queryFn: () => listComposerFiles(requireClient(client), workspaceRoot!),
    enabled: phase === 'connected' && Boolean(client && config && workspaceRoot),
    placeholderData: keepPreviousData,
  })
  const folders = useMemo(() => visualFolders(files.data ?? []), [files.data])
  const folderFiles = useMemo(
    () => folder === null ? [] : visualFilesInFolder(files.data ?? [], folder),
    [files.data, folder],
  )

  useEffect(() => {
    setFolder(null)
    setImages([])
    setSelected([])
    setFocused(0)
  }, [workspaceRoot])

  useEffect(() => {
    if (folder === null || folders.includes(folder)) return
    setFolder(null)
    setImages([])
    setSelected([])
  }, [folder, folders])

  useEffect(() => {
    setSelected([])
    setFocused(0)
    if (!client || !workspaceRoot || folder === null) {
      setImages([])
      return
    }
    let active = true
    const pending = folderFiles.map((entry) => ({ relativePath: entry.path, attachment: null }))
    setImages(pending)
    void importDaemonPathAttachments(
      client,
      folderFiles.map((entry) => workspacePath(workspaceRoot, entry.path)),
    ).then((stored) => {
      if (!active) return
      // A file the daemon could not import comes back as null; skip it the
      // way the desktop gallery does instead of leaving a spinner card.
      setImages(folderFiles.flatMap((entry, index) => {
        const attachment = stored[index]
        return attachment
          ? [{ relativePath: entry.path, attachment: galleryAttachment(attachment, entry.path) }]
          : []
      }))
    }).catch((error) => {
      if (!active) return
      setImages(pending)
      toast.error(t('visuals.load_failed', { error: errorMessage(error) }))
    })
    return () => { active = false }
  }, [client, folder, folderFiles, t, workspaceRoot])

  const selectedAttachments = images.flatMap((image) => (
    selected.includes(image.relativePath) && image.attachment ? [image.attachment] : []
  ))
  const rows = Math.ceil(images.length / columns)

  function attachSelection() {
    if (!selectedAttachments.length) {
      toast.error(t('visuals.select_first'))
      return
    }
    let attached = 0
    const detail: AttachVisualSelectionDetail = {
      sessionId,
      attachments: selectedAttachments,
      onAttached: (count) => { attached = count },
    }
    window.dispatchEvent(new CustomEvent(ATTACH_VISUAL_SELECTION_EVENT, { detail }))
    if (attached > 0) toast.success(t('visuals.attached', { count: attached }))
  }

  async function openPreview(image: GalleryImage) {
    if (!client || !image.attachment) return
    try {
      setPreview({
        name: image.attachment.name,
        source: await readAttachmentImage(client, image.attachment),
      })
    } catch (error) {
      toast.error(t('visuals.load_failed', { error: errorMessage(error) }))
    }
  }

  function moveFocus(key: VisualGridKey) {
    const next = visualGridIndex(images.length, columns, focused, key)
    if (next < 0) return
    setFocused(next)
    window.requestAnimationFrame(() => document.getElementById(cardId(next))?.focus())
  }

  const folderItems: ControlMenuItem[] = folders.map((path) => ({
    id: path || '.',
    label: path || '.',
    icon: 'folder',
    selected: path === folder,
    onSelect: () => setFolder(path),
  }))
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
          <WakuIcon className="size-3" name="folder" />
          <span className="truncate">{folder === null ? t('visuals.choose_folder') : folder || '.'}</span>
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
                : images.length === 0
                  ? <EmptyGallery title={t('visuals.no_images')} hint={t('visuals.folder_hint')} />
                  : (
                    <div aria-label={t('visuals.folder')} className="min-h-0 flex-1" role="listbox" aria-multiselectable="true">
                      <Virtuoso
                        className="h-full"
                        totalCount={rows}
                        itemContent={(row) => (
                          <div
                            className={cn(
                              'grid gap-1.5 px-2',
                              row === 0 ? 'pt-2' : 'pt-1.5',
                              row === rows - 1 && 'pb-2',
                            )}
                            style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
                          >
                            {images.slice(row * columns, (row + 1) * columns).map((image, offset) => {
                              const index = row * columns + offset
                              return (
                                <GalleryCard
                                  active={focused === index}
                                  image={image}
                                  index={index}
                                  key={image.relativePath}
                                  layout={layout}
                                  selected={selected.includes(image.relativePath)}
                                  onFocus={() => setFocused(index)}
                                  onMove={moveFocus}
                                  onOpen={() => void openPreview(image)}
                                  onToggle={() => setSelected((current) => toggleVisualSelection(current, image.relativePath))}
                                />
                              )
                            })}
                          </div>
                        )}
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
                <WakuIcon className="size-[13px]" name="x" />
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

function GalleryCard({ image, index, layout, selected, active, onToggle, onOpen, onFocus, onMove }: {
  image: GalleryImage
  index: number
  layout: VisualLayout
  selected: boolean
  active: boolean
  onToggle: () => void
  onOpen: () => void
  onFocus: () => void
  onMove: (key: VisualGridKey) => void
}) {
  const { client } = useDaemon()
  const { t } = useI18n()
  const [source, setSource] = useState<string | null>(null)
  useEffect(() => {
    if (!client || !image.attachment) {
      setSource(null)
      return
    }
    let active = true
    void readAttachmentImage(client, image.attachment)
      .then((value) => active && setSource(value))
      .catch(() => active && setSource(null))
    return () => { active = false }
  }, [client, image.attachment])
  const name = image.relativePath.split(/[\\/]/).at(-1) ?? image.relativePath

  function onKeyDown(event: ReactKeyboardEvent<HTMLButtonElement>) {
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

  return (
    <button
      aria-label={t('visuals.select_image', { name })}
      aria-selected={selected}
      className={cn(
        'group relative min-w-0 overflow-hidden rounded-lg border bg-[var(--inset)] p-[3px] text-left outline-none',
        selected ? 'border-primary bg-accent' : 'border-transparent hover:border-[var(--input)]',
        active && 'ring-1 ring-ring',
      )}
      id={cardId(index)}
      role="option"
      title={name}
      type="button"
      onClick={onToggle}
      onDoubleClick={onOpen}
      onFocus={onFocus}
      onKeyDown={onKeyDown}
    >
      {source
        ? <img alt="" className={cn('w-full rounded-[5px]', layout === 'fit' ? 'max-h-[420px] object-contain' : 'aspect-square object-cover')} src={source} />
        : <span className={cn('grid w-full place-items-center rounded-[5px]', layout === 'fit' ? 'h-52' : 'aspect-square')}><WakuIcon className="size-3.5 animate-spin text-[var(--text-ghost)]" name="loaderCircle" /></span>}
      <span className="flex h-6 items-center gap-1.5 px-1.5 text-[10.5px] text-[var(--text-tertiary)]">
        <span className="min-w-0 flex-1 truncate">{name}</span>
        {selected && <WakuIcon className="size-2.5 text-primary" name="check" />}
        <span aria-label={t('visuals.preview_image', { name })} className="sr-only" />
      </span>
    </button>
  )
}

function EmptyGallery({ title, hint, loading = false }: { title: string, hint?: string, loading?: boolean }) {
  return (
    <div className="flex min-h-0 flex-1 items-center justify-center px-7 pb-10 text-center">
      <div className="max-w-64">
        <span className="mx-auto grid size-9 place-items-center rounded-lg border bg-card text-[var(--text-tertiary)]">
          <WakuIcon className={cn('size-4', loading && 'animate-spin')} name={loading ? 'loaderCircle' : 'folder'} />
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
      <WakuIcon className="size-3 text-[var(--text-tertiary)]" name={icon} />
    </button>
  )
}

function cardId(index: number) {
  return `visual-gallery-card-${index}`
}

function requireClient<T>(client: T | null): T {
  if (!client) throw new Error('The daemon is not connected')
  return client
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error)
}

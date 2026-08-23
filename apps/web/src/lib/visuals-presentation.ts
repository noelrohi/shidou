import {
  VISUAL_COMPACT_COLUMN_WIDTH,
  VISUAL_GRID_HORIZONTAL_INSET,
  VISUAL_IMAGE_EXTENSIONS,
  VISUAL_LARGE_COLUMN_WIDTH,
  type FileEntry,
  type MessageAttachment,
} from '@waku/client'

export type VisualLayout = 'compact' | 'large' | 'fit'
export type VisualGridKey = 'ArrowLeft' | 'ArrowRight' | 'ArrowUp' | 'ArrowDown' | 'Home' | 'End'

export const VISUAL_LAYOUTS: readonly VisualLayout[] = ['compact', 'large', 'fit']
export const ATTACH_VISUAL_SELECTION_EVENT = 'pagesmith:attach-visual-selection'

const IMAGE_EXTENSIONS = new Set<string>(VISUAL_IMAGE_EXTENSIONS)

/**
 * The gallery hands its selection to the composer through a window event, and the
 * composer acknowledges how many attachments it actually staged so the gallery only
 * reports success when the attachment really happened.
 */
export interface AttachVisualSelectionDetail {
  sessionId: string | null
  attachments: MessageAttachment[]
  onAttached?: (count: number) => void
}

export function isSupportedVisualPath(path: string): boolean {
  const extension = path.split('.').at(-1)?.toLowerCase() ?? ''
  return IMAGE_EXTENSIONS.has(extension)
}

export function visualFolder(path: string): string {
  const normalized = path.replaceAll('\\', '/')
  const separator = normalized.lastIndexOf('/')
  return separator < 0 ? '' : normalized.slice(0, separator)
}

/** Only folders with direct image children are useful gallery choices. */
export function visualFolders(entries: readonly FileEntry[]): string[] {
  return [...new Set(entries
    .filter((entry) => !entry.is_dir && isSupportedVisualPath(entry.path))
    .map((entry) => visualFolder(entry.path)))]
    .sort((left, right) => left.localeCompare(right))
}

export function visualFilesInFolder(
  entries: readonly FileEntry[],
  folder: string,
): FileEntry[] {
  return entries
    .filter((entry) => (
      !entry.is_dir && isSupportedVisualPath(entry.path) && visualFolder(entry.path) === folder
    ))
    .sort((left, right) => left.path.localeCompare(right.path))
}

export function visualColumns(width: number, layout: VisualLayout): number {
  if (layout === 'fit') return 1
  const target = layout === 'compact'
    ? VISUAL_COMPACT_COLUMN_WIDTH
    : VISUAL_LARGE_COLUMN_WIDTH
  return Math.max(1, Math.floor(
    Math.max(1, width - VISUAL_GRID_HORIZONTAL_INSET) / target,
  ))
}

/**
 * Mirrored by `move_visual_gallery_focus` in `src/app/visuals.rs`; keep the
 * movement rules in sync.
 */
export function visualGridIndex(
  count: number,
  columns: number,
  current: number,
  key: VisualGridKey,
): number {
  if (count <= 0) return -1
  const index = Math.min(Math.max(current, 0), count - 1)
  if (key === 'Home') return 0
  if (key === 'End') return count - 1
  if (key === 'ArrowLeft') return Math.max(0, index - 1)
  if (key === 'ArrowRight') return Math.min(count - 1, index + 1)
  const step = Math.max(1, columns)
  if (key === 'ArrowUp') return index - step >= 0 ? index - step : index
  return index + step < count ? index + step : index
}

export function toggleVisualSelection(selected: readonly string[], path: string): string[] {
  return selected.includes(path)
    ? selected.filter((entry) => entry !== path)
    : [...selected, path]
}

export function workspacePath(root: string, relativePath: string): string {
  const separator = root.includes('\\') && !root.includes('/') ? '\\' : '/'
  return `${root.replace(/[\\/]+$/, '')}${separator}${relativePath.replace(/^[\\/]+/, '')}`
}

/** Staging is idempotent: an image already on the composer is not attached twice. */
export function mergeVisualAttachments(
  current: readonly MessageAttachment[],
  incoming: readonly MessageAttachment[],
): MessageAttachment[] {
  const next = [...current]
  for (const selected of incoming) {
    if (!next.some((attachment) => (
      attachment.path === selected.path
      || attachment.blob_reference === selected.blob_reference
    ))) next.push(selected)
  }
  return next
}

export function galleryAttachment(
  attachment: MessageAttachment,
  relativePath: string,
): MessageAttachment {
  return { ...attachment, mention: relativePath, is_image: true }
}

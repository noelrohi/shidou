import {
  VISUAL_GRID_HORIZONTAL_INSET,
  VISUAL_IMAGE_EXTENSIONS,
  type FileEntry,
  type MessageAttachment,
} from '@waku/client'

export type VisualLayout = 'compact' | 'large' | 'fit'
export type VisualGridKey = 'ArrowLeft' | 'ArrowRight' | 'ArrowUp' | 'ArrowDown' | 'Home' | 'End'

export const VISUAL_LAYOUTS: readonly VisualLayout[] = ['compact', 'large', 'fit']
export const ATTACH_VISUAL_SELECTION_EVENT = 'pagesmith:attach-visual-selection'
export const VISUAL_GALLERY_CAP = 50_000

const IMAGE_EXTENSIONS = new Set<string>(VISUAL_IMAGE_EXTENSIONS)

const VISUAL_GALLERY_GAP = 6
/** Border (2px) plus padding (2px) on each side of a card, around the image. */
const VISUAL_CARD_CHROME = 8
/** Target masonry row heights per layout; rows scale off these to justify. */
const VISUAL_MASONRY_COMPACT_ROW = 110
const VISUAL_MASONRY_LARGE_ROW = 200

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

/**
 * Whether `key` (a direct image folder) lies at or beneath the selected
 * `folder`. The empty folder is the workspace root and contains everything.
 * Mirrored by `visual_folder_contains` in `src/app/visuals.rs`.
 */
export function visualFolderContains(folder: string, key: string): boolean {
  return folder === ''
    || key === folder
    || (key.length > folder.length && key.startsWith(folder) && key[folder.length] === '/')
}

/**
 * Every selectable folder: the direct image folders plus all of their
 * ancestors up to the workspace root, so a parent like `assets/v3` can be
 * chosen to browse its subfolders together. Sorted component-wise so each
 * folder is immediately followed by its descendants — the order an indented
 * tree needs — which plain string order breaks (`pages-x` < `pages/…`).
 * Mirrored by `visual_folder_choices` in `src/app/visuals.rs`.
 */
export function visualFolderChoices(entries: readonly FileEntry[]): string[] {
  const folders = new Map<string, string[]>()
  for (const key of visualFolders(entries)) {
    const components = key === '' ? [] : key.split('/')
    for (;;) {
      folders.set(components.join('/'), [...components])
      if (components.pop() === undefined) break
    }
  }
  return [...folders.values()]
    .sort((left, right) => {
      const length = Math.min(left.length, right.length)
      for (let index = 0; index < length; index += 1) {
        if (left[index] !== right[index]) return left[index] < right[index] ? -1 : 1
      }
      return left.length - right.length
    })
    .map((components) => components.join('/'))
}

/**
 * Tree depth and display name for one folder row: the workspace root is `.`
 * at depth zero, every other folder shows only its own final segment.
 */
export function visualFolderDisplay(folder: string): { depth: number, name: string } {
  if (folder === '') return { depth: 0, name: '.' }
  const components = folder.split('/')
  return { depth: components.length, name: components.at(-1) ?? folder }
}

/** All supported images at or beneath `folder`, in stable path order. */
export function visualFilesInFolder(
  entries: readonly FileEntry[],
  folder: string,
): FileEntry[] {
  return entries
    .filter((entry) => (
      !entry.is_dir
      && isSupportedVisualPath(entry.path)
      && visualFolderContains(folder, visualFolder(entry.path))
    ))
    .sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0)
    .slice(0, VISUAL_GALLERY_CAP)
}

export interface VisualRow {
  start: number
  imageHeight: number
  widths: number[]
}

function visualAspect(size: { width: number, height: number } | undefined): number {
  const aspect = size && size.width > 0 && size.height > 0 ? size.width / size.height : 1
  return Math.min(3.2, Math.max(0.35, aspect))
}

/**
 * Justified masonry: each row is a run of images sharing a height, scaled so
 * their aspect-true widths exactly fill the panel. The final row keeps the
 * target height instead of stretching. Unknown dimensions read as square and
 * the plan rebuilds as real dimensions land. Mirrored by
 * `build_visual_row_plan` in `src/app/visuals.rs`.
 */
export function buildVisualRowPlan(
  count: number,
  sizeAt: (index: number) => { width: number, height: number } | undefined,
  layout: VisualLayout,
  panelWidth: number,
): VisualRow[] {
  if (count <= 0) return []
  const available = Math.max(1, panelWidth - VISUAL_GRID_HORIZONTAL_INSET)
  if (layout === 'fit') {
    const width = Math.max(80, available - VISUAL_CARD_CHROME)
    return Array.from({ length: count }, (_, index) => ({
      start: index,
      imageHeight: Math.min(640, Math.max(120, width / visualAspect(sizeAt(index)))),
      widths: [width],
    }))
  }
  const target = layout === 'compact' ? VISUAL_MASONRY_COMPACT_ROW : VISUAL_MASONRY_LARGE_ROW
  const plan: VisualRow[] = []
  let start = 0
  let aspects: number[] = []
  for (let index = 0; index < count; index += 1) {
    aspects.push(visualAspect(sizeAt(index)))
    const sum = aspects.reduce((total, aspect) => total + aspect, 0)
    const chrome = aspects.length * VISUAL_CARD_CHROME + (aspects.length - 1) * VISUAL_GALLERY_GAP
    const widthAtTarget = sum * target + chrome
    const last = index + 1 === count
    if (widthAtTarget >= available || last) {
      const exact = Math.max(40, (available - chrome) / sum)
      const imageHeight = widthAtTarget >= available ? exact : Math.min(exact, target)
      plan.push({
        start,
        imageHeight,
        widths: aspects.map((aspect) => aspect * imageHeight),
      })
      start = index + 1
      aspects = []
    }
  }
  return plan
}

/** Index of the masonry row containing image `index`, if any. */
export function visualRowContaining(plan: readonly VisualRow[], index: number): number {
  return plan.findIndex((row) => index >= row.start && index < row.start + row.widths.length)
}

/**
 * Mirrored by `move_visual_gallery_focus` in `src/app/visuals.rs`; keep the
 * movement rules in sync. Up/down keep the offset within the row, clamped to
 * the adjacent row's width.
 */
export function visualPlanIndex(
  plan: readonly VisualRow[],
  count: number,
  current: number,
  key: VisualGridKey,
): number {
  if (count <= 0) return -1
  const index = Math.min(Math.max(current, 0), count - 1)
  if (key === 'Home') return 0
  if (key === 'End') return count - 1
  if (key === 'ArrowLeft') return Math.max(0, index - 1)
  if (key === 'ArrowRight') return Math.min(count - 1, index + 1)
  const row = visualRowContaining(plan, index)
  if (row < 0) return index
  const adjacent = key === 'ArrowUp' ? row - 1 : row + 1
  const target = plan[adjacent]
  if (!target) return index
  const offset = index - plan[row].start
  return Math.min(target.start + offset, target.start + target.widths.length - 1)
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

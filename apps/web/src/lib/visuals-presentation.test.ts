import { describe, expect, test } from 'bun:test'
import type { FileEntry, MessageAttachment } from '@waku/client'
import {
  buildVisualRowPlan,
  galleryAttachment,
  isSupportedVisualPath,
  mergeVisualAttachments,
  toggleVisualSelection,
  visualFilesInFolder,
  visualFolder,
  visualFolderChoices,
  visualFolderContains,
  visualFolderDisplay,
  visualFolders,
  visualPlanIndex,
  visualRowContaining,
  workspacePath,
  type VisualRow,
} from './visuals-presentation'

const entries: FileEntry[] = [
  { path: 'assets/hero/a.png', is_dir: false },
  { path: 'assets/hero/b.WEBP', is_dir: false },
  { path: 'assets/hero/readme.md', is_dir: false },
  { path: 'assets/products/chair.jpg', is_dir: false },
  { path: 'assets/empty', is_dir: true },
  { path: 'logo.svg', is_dir: false },
]

describe('workspace image folders', () => {
  test('recognizes supported image extensions without treating directories as images', () => {
    expect(isSupportedVisualPath('photo.JPEG')).toBe(true)
    expect(isSupportedVisualPath('animation.gif')).toBe(true)
    expect(isSupportedVisualPath('notes.md')).toBe(false)
  })

  test('derives only folders with direct image children', () => {
    expect(visualFolders(entries)).toEqual(['', 'assets/hero', 'assets/products'])
    expect(visualFolder('logo.svg')).toBe('')
  })

  test('folder choices add ancestors sorted component-wise for an indented tree', () => {
    expect(visualFolderChoices(entries)).toEqual(['', 'assets', 'assets/hero', 'assets/products'])
    const tricky: FileEntry[] = [
      { path: 'pages-x/a.png', is_dir: false },
      { path: 'pages/deep/b.png', is_dir: false },
    ]
    expect(visualFolderChoices(tricky)).toEqual(['', 'pages', 'pages/deep', 'pages-x'])
  })

  test('a parent folder selects itself and its descendants', () => {
    expect(visualFolderContains('assets', 'assets')).toBe(true)
    expect(visualFolderContains('assets', 'assets/hero')).toBe(true)
    expect(visualFolderContains('', 'assets/hero')).toBe(true)
    expect(visualFolderContains('assets', 'assets-old')).toBe(false)
    expect(visualFolderContains('assets/hero', 'assets')).toBe(false)
    expect(visualFilesInFolder(entries, 'assets').map((entry) => entry.path))
      .toEqual(['assets/hero/a.png', 'assets/hero/b.WEBP', 'assets/products/chair.jpg'])
    expect(visualFilesInFolder(entries, '').map((entry) => entry.path))
      .toEqual(['assets/hero/a.png', 'assets/hero/b.WEBP', 'assets/products/chair.jpg', 'logo.svg'])
  })

  test('joins daemon-host paths without assuming POSIX', () => {
    expect(workspacePath('/work/shop/', 'assets/hero.png')).toBe('/work/shop/assets/hero.png')
    expect(workspacePath('C:\\work\\shop', 'assets/hero.png'))
      .toBe('C:\\work\\shop\\assets/hero.png')
  })

  test('folder rows display the root as a dot and other folders by final segment', () => {
    expect(visualFolderDisplay('')).toEqual({ depth: 0, name: '.' })
    expect(visualFolderDisplay('assets')).toEqual({ depth: 1, name: 'assets' })
    expect(visualFolderDisplay('assets/hero')).toEqual({ depth: 2, name: 'hero' })
  })
})

describe('justified masonry plan', () => {
  const square = () => ({ width: 100, height: 100 })

  test('rows justify to the available width and the last row keeps the target height', () => {
    const plan = buildVisualRowPlan(5, square, 'compact', 416)
    expect(plan.length).toBeGreaterThan(1)
    for (const row of plan.slice(0, -1)) {
      const chrome = row.widths.length * 8 + (row.widths.length - 1) * 6
      const total = row.widths.reduce((sum, width) => sum + width, 0) + chrome
      expect(Math.abs(total - 400)).toBeLessThan(0.5)
    }
    expect(plan.at(-1)!.imageHeight).toBeLessThanOrEqual(110)
  })

  test('unknown dimensions read as square and extreme aspects are clamped', () => {
    const plan = buildVisualRowPlan(2, () => undefined, 'large', 800)
    expect(plan[0].widths[0]).toBeCloseTo(plan[0].imageHeight, 3)
    const wide = buildVisualRowPlan(1, () => ({ width: 10_000, height: 100 }), 'large', 800)
    expect(wide[0].widths[0] / wide[0].imageHeight).toBeCloseTo(3.2, 3)
  })

  test('fit layout puts one full-width image per row with clamped heights', () => {
    const plan = buildVisualRowPlan(2, () => ({ width: 100, height: 4_000 }), 'fit', 700)
    expect(plan).toHaveLength(2)
    expect(plan[0].widths).toHaveLength(1)
    expect(plan[0].imageHeight).toBe(640)
  })
})

describe('keyboard navigation over the row plan', () => {
  const plan: VisualRow[] = [
    { start: 0, imageHeight: 100, widths: [100, 100, 100] },
    { start: 3, imageHeight: 100, widths: [100, 100] },
    { start: 5, imageHeight: 100, widths: [100, 100] },
  ]

  test('up and down keep the offset within the row, clamped to the shorter row', () => {
    expect(visualRowContaining(plan, 4)).toBe(1)
    expect(visualPlanIndex(plan, 7, 2, 'ArrowDown')).toBe(4)
    expect(visualPlanIndex(plan, 7, 4, 'ArrowUp')).toBe(1)
    expect(visualPlanIndex(plan, 7, 6, 'ArrowDown')).toBe(6)
    expect(visualPlanIndex(plan, 7, 0, 'ArrowUp')).toBe(0)
  })

  test('left, right, home, and end stay inside the gallery', () => {
    expect(visualPlanIndex(plan, 7, 0, 'ArrowLeft')).toBe(0)
    expect(visualPlanIndex(plan, 7, 6, 'ArrowRight')).toBe(6)
    expect(visualPlanIndex(plan, 7, 4, 'Home')).toBe(0)
    expect(visualPlanIndex(plan, 7, 4, 'End')).toBe(6)
  })
})

describe('gallery selection', () => {
  test('selection is plain multi-select', () => {
    expect(toggleVisualSelection(toggleVisualSelection([], 'a.png'), 'b.png'))
      .toEqual(['a.png', 'b.png'])
    expect(toggleVisualSelection(['a.png', 'b.png'], 'a.png')).toEqual(['b.png'])
  })

  test('composer attachment keeps durable storage but mentions the workspace file', () => {
    const stored: MessageAttachment = {
      path: '/daemon/attachments/id/hero.png',
      mention: '/work/shop/assets/hero.png',
      name: 'hero.png',
      is_dir: false,
      is_image: true,
      blob_reference: 'waku-attachment:id',
    }
    expect(galleryAttachment(stored, 'assets/hero.png')).toEqual({
      ...stored,
      mention: 'assets/hero.png',
    })
  })
})

describe('staging a gallery selection on the composer', () => {
  const staged: MessageAttachment[] = [
    { name: 'a.png', path: '/work/a.png', mention: 'a.png', is_dir: false, is_image: true, blob_reference: 'blob:a' },
  ]

  test('appends new attachments and skips ones already staged', () => {
    const incoming: MessageAttachment[] = [
      { name: 'a.png', path: '/work/a.png', mention: 'a.png', is_dir: false, is_image: true, blob_reference: 'blob:a' },
      { name: 'b.png', path: '/work/b.png', mention: 'b.png', is_dir: false, is_image: true, blob_reference: 'blob:b' },
    ]
    expect(mergeVisualAttachments(staged, incoming).map((entry) => entry.name))
      .toEqual(['a.png', 'b.png'])
    expect(mergeVisualAttachments(staged, staged)).toEqual(staged)
  })
})

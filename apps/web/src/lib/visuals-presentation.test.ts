import { describe, expect, test } from 'bun:test'
import type { FileEntry, MessageAttachment } from '@waku/client'
import {
  galleryAttachment,
  isSupportedVisualPath,
  mergeVisualAttachments,
  toggleVisualSelection,
  visualColumns,
  visualFilesInFolder,
  visualFolder,
  visualFolders,
  visualGridIndex,
  workspacePath,
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
    expect(visualFilesInFolder(entries, 'assets/hero').map((entry) => entry.path))
      .toEqual(['assets/hero/a.png', 'assets/hero/b.WEBP'])
    expect(visualFolder('logo.svg')).toBe('')
  })

  test('joins daemon-host paths without assuming POSIX', () => {
    expect(workspacePath('/work/shop/', 'assets/hero.png')).toBe('/work/shop/assets/hero.png')
    expect(workspacePath('C:\\work\\shop', 'assets/hero.png'))
      .toBe('C:\\work\\shop\\assets/hero.png')
  })
})

describe('gallery layout and selection', () => {
  test('compact, large, and fit layouts choose useful column counts', () => {
    expect(visualColumns(700, 'compact')).toBe(6)
    expect(visualColumns(700, 'large')).toBe(3)
    expect(visualColumns(700, 'fit')).toBe(1)
    expect(visualColumns(280, 'large')).toBe(1)
  })

  test('keyboard navigation stays inside the gallery', () => {
    expect(visualGridIndex(7, 3, 0, 'ArrowDown')).toBe(3)
    expect(visualGridIndex(7, 3, 6, 'ArrowDown')).toBe(6)
    expect(visualGridIndex(7, 3, 4, 'ArrowUp')).toBe(1)
    expect(visualGridIndex(7, 3, 4, 'Home')).toBe(0)
    expect(visualGridIndex(7, 3, 4, 'End')).toBe(6)
  })

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

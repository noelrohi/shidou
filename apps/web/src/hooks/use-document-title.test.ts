import { describe, expect, test } from 'bun:test'
import {
  formatDocumentTitle,
  SHIDOU_DOCUMENT_TITLE,
} from './use-document-title'

describe('formatDocumentTitle', () => {
  test('uses the product title without a section', () => {
    expect(formatDocumentTitle()).toBe(SHIDOU_DOCUMENT_TITLE)
    expect(formatDocumentTitle('   ')).toBe(SHIDOU_DOCUMENT_TITLE)
  })

  test('identifies the current browser surface', () => {
    expect(formatDocumentTitle('New Task')).toBe('New Task — Shidou Web')
    expect(formatDocumentTitle('  General  ')).toBe('General — Shidou Web')
  })

  test('does not duplicate the product title', () => {
    expect(formatDocumentTitle(SHIDOU_DOCUMENT_TITLE)).toBe(SHIDOU_DOCUMENT_TITLE)
  })
})

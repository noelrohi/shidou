import { useEffect } from 'react'

export const SHIDOU_DOCUMENT_TITLE = 'Shidou Web'

export function formatDocumentTitle(section?: string | null): string {
  const normalized = section?.trim()
  if (!normalized || normalized === SHIDOU_DOCUMENT_TITLE) return SHIDOU_DOCUMENT_TITLE
  return `${normalized} — ${SHIDOU_DOCUMENT_TITLE}`
}

export function useDocumentTitle(section?: string | null) {
  const title = formatDocumentTitle(section)
  useEffect(() => {
    document.title = title
  }, [title])
}

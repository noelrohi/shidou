/**
 * Find-in-transcript over the virtualized message list.
 *
 * Matches are computed from message content so the count and navigation cover
 * the whole transcript even though only a window of rows is mounted. DOM
 * highlighting is layered on separately (CSS Custom Highlight API) and only
 * ever touches mounted rows.
 */

export const TRANSCRIPT_SEARCH_MATCH_LIMIT = 20_000

export interface SearchableTranscriptItem {
  key: string
  text: string
}

export interface TranscriptSearchMatch {
  /** Index into the transcript render items. */
  itemIndex: number
  /** Render item key, used to locate the mounted row for highlighting. */
  itemKey: string
  /** Zero-based occurrence of the query within this item's text. */
  ordinal: number
}

export interface TranscriptSearchResult {
  matches: TranscriptSearchMatch[]
  limited: boolean
}

export function findTranscriptMatches(
  items: readonly (SearchableTranscriptItem | null)[],
  query: string,
  limit = TRANSCRIPT_SEARCH_MATCH_LIMIT,
): TranscriptSearchResult {
  const matches: TranscriptSearchMatch[] = []
  const needle = query.toLowerCase()
  if (!needle) return { matches, limited: false }
  for (let itemIndex = 0; itemIndex < items.length; itemIndex += 1) {
    const item = items[itemIndex]
    if (!item) continue
    const haystack = item.text.toLowerCase()
    let at = haystack.indexOf(needle)
    let ordinal = 0
    while (at >= 0) {
      if (matches.length >= limit) return { matches, limited: true }
      matches.push({ itemIndex, itemKey: item.key, ordinal })
      ordinal += 1
      at = haystack.indexOf(needle, at + needle.length)
    }
  }
  return { matches, limited: false }
}

export function stepSearchMatch(
  current: number | null,
  count: number,
  backward: boolean,
): number | null {
  if (!count) return null
  if (current === null) return backward ? count - 1 : 0
  return backward ? (current - 1 + count) % count : (current + 1) % count
}

/**
 * Keeps the current match pointed at the same position when the match list is
 * rebuilt (streaming appends, folds toggling). Falls back to clamping.
 */
export function reconcileSearchCurrent(
  previous: TranscriptSearchMatch | null,
  matches: readonly TranscriptSearchMatch[],
): number | null {
  if (!matches.length) return null
  if (!previous) return null
  const exact = matches.findIndex(
    (match) => match.itemKey === previous.itemKey && match.ordinal === previous.ordinal,
  )
  if (exact >= 0) return exact
  const sameItem = matches.findIndex((match) => match.itemKey === previous.itemKey)
  if (sameItem >= 0) return sameItem
  return Math.min(matches.length - 1, Math.max(0, matches.findIndex((match) => match.itemIndex >= previous.itemIndex)))
}

/** Collect DOM ranges for every query occurrence under `root`, in text order. */
export function collectSearchRanges(root: Node, query: string): Range[] {
  const needle = query.toLowerCase()
  if (!needle) return []
  const ranges: Range[] = []
  const document = root.ownerDocument ?? (root as Document)
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (node) => {
      const parent = node.parentElement
      if (!parent) return NodeFilter.FILTER_REJECT
      if (parent.closest('textarea, input, [data-transcript-search-skip]')) {
        return NodeFilter.FILTER_REJECT
      }
      return NodeFilter.FILTER_ACCEPT
    },
  })
  let node = walker.nextNode()
  while (node) {
    const text = node.textContent ?? ''
    const haystack = text.toLowerCase()
    let at = haystack.indexOf(needle)
    while (at >= 0) {
      const range = document.createRange()
      range.setStart(node, at)
      range.setEnd(node, at + needle.length)
      ranges.push(range)
      at = haystack.indexOf(needle, at + needle.length)
    }
    node = walker.nextNode()
  }
  return ranges
}

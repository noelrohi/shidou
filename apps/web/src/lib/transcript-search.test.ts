import { describe, expect, test } from 'bun:test'
import {
  findTranscriptMatches,
  reconcileSearchCurrent,
  stepSearchMatch,
} from './transcript-search'

const items = [
  { key: 'a', text: 'Alpha beta ALPHA' },
  { key: 'b', text: 'nothing here' },
  { key: 'c', text: 'alphabet' },
]

describe('transcript search matching', () => {
  test('matches case-insensitively across items with per-item ordinals', () => {
    const { matches, limited } = findTranscriptMatches(items, 'alpha')
    expect(limited).toBe(false)
    expect(matches).toEqual([
      { itemIndex: 0, itemKey: 'a', ordinal: 0 },
      { itemIndex: 0, itemKey: 'a', ordinal: 1 },
      { itemIndex: 2, itemKey: 'c', ordinal: 0 },
    ])
  })

  test('an empty query and empty items yield no matches', () => {
    expect(findTranscriptMatches(items, '').matches).toHaveLength(0)
    expect(findTranscriptMatches([], 'alpha').matches).toHaveLength(0)
  })

  test('stops at the match limit and reports truncation', () => {
    const { matches, limited } = findTranscriptMatches(items, 'alpha', 2)
    expect(limited).toBe(true)
    expect(matches).toHaveLength(2)
  })

  test('navigation wraps forward and backward', () => {
    expect(stepSearchMatch(null, 3, false)).toBe(0)
    expect(stepSearchMatch(null, 3, true)).toBe(2)
    expect(stepSearchMatch(2, 3, false)).toBe(0)
    expect(stepSearchMatch(0, 3, true)).toBe(2)
    expect(stepSearchMatch(0, 0, false)).toBeNull()
  })

  test('reconciles the current match after the list is rebuilt', () => {
    const { matches } = findTranscriptMatches(items, 'alpha')
    expect(reconcileSearchCurrent(matches[1]!, matches)).toBe(1)
    const shrunk = findTranscriptMatches([items[0]!], 'alpha').matches
    expect(reconcileSearchCurrent(matches[2]!, shrunk)).toBe(0)
    expect(reconcileSearchCurrent(matches[0]!, [])).toBeNull()
  })
})

import { describe, expect, test } from 'bun:test'
import {
  cycleHighlightIndex,
  initialHighlightIndex,
  orderedTaskIds,
  recordTaskAccess,
  taskSwitcherColumns,
} from './task-switcher'

describe('task switcher ordering', () => {
  test('contains only the ten most recently visited tasks', () => {
    const recent = Array.from({ length: 14 }, (_, index) => `recent-${index}`)
    const started = ['current', ...recent]
    const ordered = orderedTaskIds('current', recent, started)
    expect(ordered).toHaveLength(10)
    expect(ordered[0]).toBe('current')
    expect(ordered.slice(1)).toEqual(recent.slice(0, 9))
  })

  test('drops removed and never-started tasks from the order', () => {
    const ordered = orderedTaskIds('current', ['gone', 'draft', 'kept'], ['current', 'kept'])
    expect(ordered).toEqual(['current', 'kept'])
  })

  test('first forward press targets the previous task and reverse wraps', () => {
    const ordered = ['current', 'previous', 'older']
    expect(initialHighlightIndex(ordered, 'current', false)).toBe(1)
    expect(initialHighlightIndex(ordered, 'current', true)).toBe(2)
  })

  test('a single current task still opens the switcher', () => {
    expect(initialHighlightIndex(['current'], 'current', false)).toBe(0)
  })

  test('a draft can switch to the only visited started task', () => {
    const ordered = orderedTaskIds(undefined, ['visited'], ['visited'])
    expect(ordered).toEqual(['visited'])
    expect(initialHighlightIndex(ordered, undefined, false)).toBe(0)
  })

  test('cycling wraps in both directions', () => {
    expect(cycleHighlightIndex(2, 3, false)).toBe(0)
    expect(cycleHighlightIndex(0, 3, true)).toBe(2)
  })

  test('grid caps at ten tasks and two rows', () => {
    expect(taskSwitcherColumns(3)).toBe(3)
    expect(taskSwitcherColumns(6)).toBe(3)
    expect(taskSwitcherColumns(10)).toBe(5)
    expect(taskSwitcherColumns(25)).toBe(5)
  })

  test('recording access moves the task to the front once', () => {
    expect(recordTaskAccess(['a', 'b'], 'b')).toEqual(['b', 'a'])
    expect(recordTaskAccess(['b', 'a'], 'b')).toEqual(['b', 'a'])
  })
})

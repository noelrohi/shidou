import { describe, expect, test } from 'bun:test'
import {
  BoundedMermaidCache,
  MAX_MERMAID_SOURCE_CHARS,
  mermaidFence,
  mermaidRenderKey,
  type MarkdownElement,
} from './mermaid-fence'

function pre(className: unknown, children: MarkdownElement['children']): MarkdownElement {
  return {
    type: 'element',
    tagName: 'pre',
    children: [{
      type: 'element',
      tagName: 'code',
      properties: { className },
      children,
    }],
  }
}

describe('Mermaid markdown fences', () => {
  test('recognizes only explicit mermaid code fences and keeps their source readable', () => {
    const fence = mermaidFence(pre(['language-mermaid'], [
      { type: 'text', value: 'graph TD\n  A --> B\n' },
    ]))

    expect(fence).toEqual({ source: 'graph TD\n  A --> B', renderable: true })
    expect(mermaidFence(pre(['language-typescript'], [
      { type: 'text', value: 'const diagram = true\n' },
    ]))).toBeNull()
  })

  test('recovers source split by the streaming veil but waits for the fence to settle', () => {
    const node = pre('language-mermaid', [{
      type: 'element',
      tagName: 'span',
      children: [
        { type: 'text', value: 'sequence' },
        { type: 'text', value: 'Diagram\nA->>B: Hi\n' },
      ],
    }])

    expect(mermaidFence(node, true)).toEqual({
      source: 'sequenceDiagram\nA->>B: Hi',
      renderable: false,
    })
  })

  test('leaves empty and oversized diagrams as code', () => {
    expect(mermaidFence(pre(['language-mermaid'], [
      { type: 'text', value: '\n' },
    ]))).toEqual({ source: '', renderable: false })
    expect(mermaidFence(pre(['language-mermaid'], [
      { type: 'text', value: 'x'.repeat(MAX_MERMAID_SOURCE_CHARS + 1) },
    ]))?.renderable).toBe(false)
  })
})

describe('Mermaid render cache', () => {
  test('keys entries by source and resolved theme', () => {
    expect(mermaidRenderKey('graph TD\nA-->B', 'light')).not.toBe(
      mermaidRenderKey('graph TD\nA-->B', 'dark'),
    )
  })

  test('evicts the least recently used render at its bound', () => {
    const cache = new BoundedMermaidCache<string>(2)
    cache.set('first', 'one')
    cache.set('second', 'two')
    expect(cache.get('first')).toBe('one')
    cache.set('third', 'three')

    expect(cache.get('first')).toBe('one')
    expect(cache.get('second')).toBeUndefined()
    expect(cache.get('third')).toBe('three')
    expect(cache.size).toBe(2)
  })
})

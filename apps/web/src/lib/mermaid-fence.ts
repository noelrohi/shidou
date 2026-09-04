export const MAX_MERMAID_SOURCE_CHARS = 20_000

export type MermaidTheme = 'light' | 'dark'

export type MarkdownNode = {
  type: string
  value?: string
  tagName?: string
  properties?: Record<string, unknown>
  children?: MarkdownNode[]
}

export type MarkdownElement = MarkdownNode & {
  type: 'element'
  tagName: string
}

export type MermaidFence = {
  source: string
  renderable: boolean
}

/** Classify the HAST node supplied to react-markdown's `pre` renderer. */
export function mermaidFence(
  pre: MarkdownElement | undefined,
  streaming = false,
): MermaidFence | null {
  if (pre?.tagName !== 'pre' || pre.children?.length !== 1) return null
  const code = pre.children[0]
  if (code?.type !== 'element' || code.tagName !== 'code') return null
  if (!classes(code.properties?.className).includes('language-mermaid')) return null

  const source = textContent(code).replace(/\n$/, '')
  return {
    source,
    renderable: !streaming
      && source.trim().length > 0
      && source.length <= MAX_MERMAID_SOURCE_CHARS,
  }
}

function classes(value: unknown): string[] {
  if (Array.isArray(value)) return value.filter((item): item is string => typeof item === 'string')
  return typeof value === 'string' ? value.split(/\s+/) : []
}

function textContent(node: MarkdownNode): string {
  if (node.type === 'text') return node.value ?? ''
  if (node.type !== 'element') return ''
  return node.children?.map(textContent).join('') ?? ''
}

export function mermaidRenderKey(source: string, theme: MermaidTheme): string {
  return JSON.stringify([theme, source])
}

export class BoundedMermaidCache<Value> {
  readonly #entries = new Map<string, Value>()

  constructor(readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) throw new Error('Cache limit must be a positive integer')
  }

  get size(): number {
    return this.#entries.size
  }

  get(key: string): Value | undefined {
    const value = this.#entries.get(key)
    if (value === undefined) return undefined
    this.#entries.delete(key)
    this.#entries.set(key, value)
    return value
  }

  set(key: string, value: Value): void {
    this.#entries.delete(key)
    this.#entries.set(key, value)
    while (this.#entries.size > this.limit) {
      const oldest = this.#entries.keys().next().value
      if (oldest === undefined) break
      this.#entries.delete(oldest)
    }
  }

  delete(key: string): void {
    this.#entries.delete(key)
  }
}

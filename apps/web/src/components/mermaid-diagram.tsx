import { useEffect, useState, type ReactNode } from 'react'
import {
  BoundedMermaidCache,
  MAX_MERMAID_SOURCE_CHARS,
  mermaidRenderKey,
  type MermaidTheme,
} from '@/lib/mermaid-fence'

const MERMAID_CACHE_LIMIT = 32
const MERMAID_MAX_EDGES = 300
const renderedDiagrams = new BoundedMermaidCache<Promise<string>>(MERMAID_CACHE_LIMIT)
let mermaidModule: Promise<typeof import('mermaid')['default']> | undefined
let renderQueue: Promise<void> = Promise.resolve()
let renderId = 0

export function MermaidDiagram({
  source,
  fallback,
}: {
  source: string
  fallback: ReactNode
}) {
  const theme = useMermaidTheme()
  const [svg, setSvg] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    let cancelIdle: (() => void) | undefined
    setSvg(null)

    const render = () => {
      void renderMermaid(source, theme).then(
        (result) => {
          if (!cancelled) setSvg(result)
        },
        () => {
          // The readable code fence remains in place when Mermaid rejects input.
        },
      )
    }

    if (typeof window.requestIdleCallback === 'function') {
      const idle = window.requestIdleCallback(render, { timeout: 500 })
      cancelIdle = () => window.cancelIdleCallback(idle)
    } else {
      const timer = window.setTimeout(render, 0)
      cancelIdle = () => window.clearTimeout(timer)
    }

    return () => {
      cancelled = true
      cancelIdle?.()
    }
  }, [source, theme])

  if (!svg) return fallback
  return (
    <div
      className="mermaid-diagram"
      data-transcript-search-skip
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}

function useMermaidTheme(): MermaidTheme {
  const [theme, setTheme] = useState<MermaidTheme>(resolvedTheme)

  useEffect(() => {
    const update = () => setTheme(resolvedTheme())
    const observer = new MutationObserver(update)
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
    const media = window.matchMedia('(prefers-color-scheme: dark)')
    media.addEventListener('change', update)
    update()
    return () => {
      observer.disconnect()
      media.removeEventListener('change', update)
    }
  }, [])

  return theme
}

function resolvedTheme(): MermaidTheme {
  return typeof document !== 'undefined' && document.documentElement.classList.contains('dark')
    ? 'dark'
    : 'light'
}

function renderMermaid(source: string, theme: MermaidTheme): Promise<string> {
  const key = mermaidRenderKey(source, theme)
  const cached = renderedDiagrams.get(key)
  if (cached) return cached

  const pending = enqueueRender(async () => {
    mermaidModule ??= import('mermaid').then(({ default: mermaid }) => mermaid)
    const mermaid = await mermaidModule
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      secure: [
        'secure',
        'securityLevel',
        'startOnLoad',
        'maxTextSize',
        'maxEdges',
        'suppressErrorRendering',
        'htmlLabels',
        'dompurifyConfig',
      ],
      htmlLabels: false,
      suppressErrorRendering: true,
      maxTextSize: MAX_MERMAID_SOURCE_CHARS,
      maxEdges: MERMAID_MAX_EDGES,
      deterministicIds: true,
      deterministicIDSeed: key,
      fontFamily: 'Geist Variable, sans-serif',
      theme: theme === 'dark' ? 'dark' : 'default',
    })
    renderId += 1
    const { svg } = await mermaid.render(`shidou-mermaid-${renderId}`, source)
    return svg
  })
  renderedDiagrams.set(key, pending)
  void pending.catch(() => renderedDiagrams.delete(key))
  return pending
}

function enqueueRender<Value>(render: () => Promise<Value>): Promise<Value> {
  const pending = renderQueue.then(render, render)
  renderQueue = pending.then(() => undefined, () => undefined)
  return pending
}

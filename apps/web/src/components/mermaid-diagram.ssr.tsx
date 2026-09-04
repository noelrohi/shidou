import type { ReactNode } from 'react'

/** Server-side stand-in. The client initially renders the same readable fence. */
export function MermaidDiagram({ fallback }: { source: string; fallback: ReactNode }) {
  return fallback
}

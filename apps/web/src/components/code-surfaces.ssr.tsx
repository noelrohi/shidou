// Server-side stand-in for code-surfaces.tsx, swapped in by the ssrStubCodeSurfaces
// plugin in vite.config.ts. Code surfaces are client-only (web workers, DOM
// measurement), but bundling the real module into the SSR build drags every
// Shiki grammar along and pushes the Worker over Cloudflare's size limit.
import { forwardRef } from 'react'
import type { CodeDiffSurfaceHandle } from './code-surfaces'

export type { CodeDiffSurfaceHandle, DiffSurfaceFile } from './code-surfaces'

export function preloadCodeSurfaces(): Promise<void> {
  return Promise.resolve()
}

export function CodeFileSurface(): null {
  return null
}

export const CodeDiffSurface = forwardRef<CodeDiffSurfaceHandle, unknown>(
  function CodeDiffSurface() {
    return null
  },
)

import { cloudflare } from '@cloudflare/vite-plugin'
import babel from '@rolldown/plugin-babel'
import tailwindcss from '@tailwindcss/vite'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact, { reactCompilerPreset } from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

// Keep DOM-heavy client dependencies out of the Cloudflare Worker. The code
// surface stub avoids bundling every Shiki grammar; the Mermaid stub preserves
// the readable code fence without bundling the diagram engine into SSR.
function ssrStubClientOnlyComponents(): Plugin {
  const stubs = new Map([
    ['@/components/code-surfaces', './src/components/code-surfaces.ssr.tsx'],
    ['@/components/mermaid-diagram', './src/components/mermaid-diagram.ssr.tsx'],
  ])
  return {
    name: 'ssr-stub-client-only-components',
    enforce: 'pre',
    resolveId(source) {
      const stub = this.environment?.name === 'ssr' ? stubs.get(source) : undefined
      if (stub) return fileURLToPath(new URL(stub, import.meta.url))
    },
  }
}

export default defineConfig({
  server: {
    port: 3001,
  },
  resolve: {
    tsconfigPaths: true,
  },
  optimizeDeps: {
    // Keep the core, React wrapper, and editor on one resolved package version.
    // Otherwise a running dev server can retain the pre-editor React bundle
    // while discovering the new editor entry after a dependency update.
    include: ['@pierre/diffs', '@pierre/diffs/edit', '@pierre/diffs/react'],
  },
  worker: {
    format: 'es',
  },
  plugins: [
    ssrStubClientOnlyComponents(),
    tailwindcss(),
    cloudflare({ viteEnvironment: { name: 'ssr' } }),
    tanstackStart(),
    viteReact(),
    babel({ presets: [reactCompilerPreset()] }),
  ],
})

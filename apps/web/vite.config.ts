import { cloudflare } from '@cloudflare/vite-plugin'
import babel from '@rolldown/plugin-babel'
import tailwindcss from '@tailwindcss/vite'
import { tanstackStart } from '@tanstack/react-start/plugin/vite'
import viteReact, { reactCompilerPreset } from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

// Code surfaces are client-only, but their SSR chunk pulls in every Shiki
// grammar and pushes the Worker past Cloudflare's size limit. Swap the module
// for a null-rendering stub in the ssr environment only.
function ssrStubCodeSurfaces(): Plugin {
  return {
    name: 'ssr-stub-code-surfaces',
    enforce: 'pre',
    resolveId(source) {
      if (
        this.environment?.name === 'ssr' &&
        source === '@/components/code-surfaces'
      ) {
        return fileURLToPath(
          new URL('./src/components/code-surfaces.ssr.tsx', import.meta.url),
        )
      }
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
    ssrStubCodeSurfaces(),
    tailwindcss(),
    cloudflare({ viteEnvironment: { name: 'ssr' } }),
    tanstackStart(),
    viteReact(),
    babel({ presets: [reactCompilerPreset()] }),
  ],
})

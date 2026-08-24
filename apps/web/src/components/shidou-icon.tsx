import type { ProviderKind } from '@shidou/client'

const ICON_ASSETS = {
  ...import.meta.glob('../../../../assets/icons/*.svg', {
    eager: true,
    import: 'default',
    query: '?url',
  }),
  ...import.meta.glob('../../../../assets/icons/file-types/*.svg', {
    eager: true,
    import: 'default',
    query: '?url',
  }),
} as Record<string, string>

function iconAsset(path: string) {
  const url = ICON_ASSETS[`../../../../assets/icons/${path}`]
  if (!url) throw new Error(`Missing icon asset: ${path}`)
  return url
}

export const SHIDOU_ICONS = {
  alert: iconAsset('alert.svg'),
  appearance: iconAsset('appearance.svg'),
  arrowDown: iconAsset('arrow-down.svg'),
  arrowLeft: iconAsset('arrow-left.svg'),
  arrowRight: iconAsset('arrow-right.svg'),
  arrowUp: iconAsset('arrow-up.svg'),
  arrowUpRight: iconAsset('arrow-up-right.svg'),
  bot: iconAsset('bot.svg'),
  chartColumn: iconAsset('chart-column.svg'),
  check: iconAsset('check.svg'),
  chevronDown: iconAsset('chevron-down.svg'),
  chevronRight: iconAsset('chevron-right.svg'),
  cloudUpload: iconAsset('cloud-upload.svg'),
  command: iconAsset('command.svg'),
  compose: iconAsset('compose.svg'),
  copy: iconAsset('copy.svg'),
  cornerDownRight: iconAsset('corner-down-right.svg'),
  ellipsis: iconAsset('ellipsis.svg'),
  eye: iconAsset('eye.svg'),
  eyeOff: iconAsset('eye-off.svg'),
  file: iconAsset('file.svg'),
  fileDiff: iconAsset('file-diff.svg'),
  folder: iconAsset('folder.svg'),
  folderNew: iconAsset('folder-new.svg'),
  fork: iconAsset('fork.svg'),
  gauge: iconAsset('gauge.svg'),
  gitBranch: iconAsset('git-branch.svg'),
  gitCommitHorizontal: iconAsset('git-commit-horizontal.svg'),
  globe: iconAsset('globe.svg'),
  github: iconAsset('github.svg'),
  info: iconAsset('info.svg'),
  laptop: iconAsset('laptop.svg'),
  list: iconAsset('list.svg'),
  listFilter: iconAsset('list-filter.svg'),
  loaderCircle: iconAsset('loader-circle.svg'),
  lock: iconAsset('lock.svg'),
  lockOpen: iconAsset('lock-open.svg'),
  package: iconAsset('package.svg'),
  paperclip: iconAsset('paperclip.svg'),
  panelLeft: iconAsset('panel-left.svg'),
  panelRight: iconAsset('panel-right.svg'),
  pencil: iconAsset('pencil.svg'),
  plus: iconAsset('plus.svg'),
  queue: iconAsset('queue.svg'),
  rotateCw: iconAsset('rotate-cw.svg'),
  rewind: iconAsset('rewind.svg'),
  search: iconAsset('search.svg'),
  server: iconAsset('server.svg'),
  settings: iconAsset('settings.svg'),
  sparkle: iconAsset('sparkle.svg'),
  star: iconAsset('star.svg'),
  starFilled: iconAsset('star-filled.svg'),
  stop: iconAsset('stop.svg'),
  stopFilled: iconAsset('stop-filled.svg'),
  terminal: iconAsset('terminal.svg'),
  terminalSquare: iconAsset('terminal-square.svg'),
  trash: iconAsset('trash.svg'),
  wrench: iconAsset('wrench.svg'),
  x: iconAsset('x.svg'),
  zap: iconAsset('zap.svg'),
} as const

export type ShidouIconName = keyof typeof SHIDOU_ICONS

export function ShidouIcon({
  name,
  className,
  label,
}: {
  name: ShidouIconName
  className?: string
  label?: string
}) {
  const url = SHIDOU_ICONS[name]
  return (
    <span
      aria-hidden={label ? undefined : true}
      aria-label={label}
      className={`inline-block size-4 shrink-0 bg-current ${className ?? ''}`}
      role={label ? 'img' : undefined}
      style={{
        maskImage: `url(${url})`,
        maskPosition: 'center',
        maskRepeat: 'no-repeat',
        maskSize: 'contain',
        WebkitMaskImage: `url(${url})`,
      }}
    />
  )
}

const FILE_TYPE_ICONS = {
  angular: iconAsset('file-types/angular.svg'),
  astro: iconAsset('file-types/astro.svg'),
  audio: iconAsset('file-types/audio.svg'),
  babel: iconAsset('file-types/babel.svg'),
  biome: iconAsset('file-types/biome.svg'),
  bun: iconAsset('file-types/bun.svg'),
  c: iconAsset('file-types/c.svg'),
  certificate: iconAsset('file-types/certificate.svg'),
  clojure: iconAsset('file-types/clojure.svg'),
  cmake: iconAsset('file-types/cmake.svg'),
  coffee: iconAsset('file-types/coffee.svg'),
  console: iconAsset('file-types/console.svg'),
  cpp: iconAsset('file-types/cpp.svg'),
  crystal: iconAsset('file-types/crystal.svg'),
  csharp: iconAsset('file-types/csharp.svg'),
  css: iconAsset('file-types/css.svg'),
  dart: iconAsset('file-types/dart.svg'),
  database: iconAsset('file-types/database.svg'),
  deno: iconAsset('file-types/deno.svg'),
  diff: iconAsset('file-types/diff.svg'),
  docker: iconAsset('file-types/docker.svg'),
  editorconfig: iconAsset('file-types/editorconfig.svg'),
  elixir: iconAsset('file-types/elixir.svg'),
  elm: iconAsset('file-types/elm.svg'),
  erlang: iconAsset('file-types/erlang.svg'),
  eslint: iconAsset('file-types/eslint.svg'),
  exe: iconAsset('file-types/exe.svg'),
  file: iconAsset('file-types/file.svg'),
  firebase: iconAsset('file-types/firebase.svg'),
  git: iconAsset('file-types/git.svg'),
  gitlab: iconAsset('file-types/gitlab.svg'),
  go: iconAsset('file-types/go.svg'),
  gradle: iconAsset('file-types/gradle.svg'),
  graphql: iconAsset('file-types/graphql.svg'),
  haskell: iconAsset('file-types/haskell.svg'),
  haxe: iconAsset('file-types/haxe.svg'),
  helm: iconAsset('file-types/helm.svg'),
  html: iconAsset('file-types/html.svg'),
  image: iconAsset('file-types/image.svg'),
  java: iconAsset('file-types/java.svg'),
  javascript: iconAsset('file-types/javascript.svg'),
  jinja: iconAsset('file-types/jinja.svg'),
  json: iconAsset('file-types/json.svg'),
  julia: iconAsset('file-types/julia.svg'),
  kotlin: iconAsset('file-types/kotlin.svg'),
  kubernetes: iconAsset('file-types/kubernetes.svg'),
  lock: iconAsset('file-types/lock.svg'),
  lua: iconAsset('file-types/lua.svg'),
  makefile: iconAsset('file-types/makefile.svg'),
  markdown: iconAsset('file-types/markdown.svg'),
  nest: iconAsset('file-types/nest.svg'),
  next: iconAsset('file-types/next.svg'),
  nginx: iconAsset('file-types/nginx.svg'),
  nix: iconAsset('file-types/nix.svg'),
  nodejs: iconAsset('file-types/nodejs.svg'),
  npm: iconAsset('file-types/npm.svg'),
  nuxt: iconAsset('file-types/nuxt.svg'),
  ocaml: iconAsset('file-types/ocaml.svg'),
  pdf: iconAsset('file-types/pdf.svg'),
  perl: iconAsset('file-types/perl.svg'),
  php: iconAsset('file-types/php.svg'),
  pnpm: iconAsset('file-types/pnpm.svg'),
  powershell: iconAsset('file-types/powershell.svg'),
  prettier: iconAsset('file-types/prettier.svg'),
  prisma: iconAsset('file-types/prisma.svg'),
  proto: iconAsset('file-types/proto.svg'),
  pug: iconAsset('file-types/pug.svg'),
  python: iconAsset('file-types/python.svg'),
  react: iconAsset('file-types/react.svg'),
  readme: iconAsset('file-types/readme.svg'),
  rollup: iconAsset('file-types/rollup.svg'),
  ruby: iconAsset('file-types/ruby.svg'),
  rust: iconAsset('file-types/rust.svg'),
  sass: iconAsset('file-types/sass.svg'),
  scala: iconAsset('file-types/scala.svg'),
  settings: iconAsset('file-types/settings.svg'),
  solidity: iconAsset('file-types/solidity.svg'),
  storybook: iconAsset('file-types/storybook.svg'),
  stylelint: iconAsset('file-types/stylelint.svg'),
  supabase: iconAsset('file-types/supabase.svg'),
  svelte: iconAsset('file-types/svelte.svg'),
  svg: iconAsset('file-types/svg.svg'),
  swift: iconAsset('file-types/swift.svg'),
  tailwindcss: iconAsset('file-types/tailwindcss.svg'),
  terraform: iconAsset('file-types/terraform.svg'),
  tex: iconAsset('file-types/tex.svg'),
  turborepo: iconAsset('file-types/turborepo.svg'),
  typescript: iconAsset('file-types/typescript.svg'),
  video: iconAsset('file-types/video.svg'),
  vite: iconAsset('file-types/vite.svg'),
  vitest: iconAsset('file-types/vitest.svg'),
  vue: iconAsset('file-types/vue.svg'),
  webassembly: iconAsset('file-types/webassembly.svg'),
  webpack: iconAsset('file-types/webpack.svg'),
  xaml: iconAsset('file-types/xaml.svg'),
  xml: iconAsset('file-types/xml.svg'),
  yaml: iconAsset('file-types/yaml.svg'),
  yarn: iconAsset('file-types/yarn.svg'),
  zig: iconAsset('file-types/zig.svg'),
  zip: iconAsset('file-types/zip.svg'),
} as const

type FileTypeIconName = keyof typeof FILE_TYPE_ICONS

export function FileTypeIcon({
  path,
  className,
}: {
  path: string
  className?: string
}) {
  const name = fileTypeIconName(path)
  return (
    <span
      aria-hidden="true"
      className={`inline-grid size-4 shrink-0 place-items-center ${className ?? ''}`}
    >
      <img alt="" className="size-full" src={FILE_TYPE_ICONS[name]} />
    </span>
  )
}

function fileTypeIconName(path: string): FileTypeIconName {
  const name = path.split(/[\\/]/).at(-1)?.toLocaleLowerCase() ?? path.toLocaleLowerCase()
  if (name.startsWith('readme')) return 'readme'
  if (/^(license|licence|copying)/.test(name)) return 'certificate'
  if (name.startsWith('dockerfile') || name.startsWith('compose.')) return 'docker'
  if (name === 'cmakelists.txt' || name.startsWith('cmake.')) return 'cmake'
  if (name === 'makefile' || name.startsWith('makefile.') || name === 'justfile') return 'makefile'
  if (['cargo.toml', 'cargo.lock', 'rust-toolchain.toml'].includes(name)) return 'rust'
  if (['go.mod', 'go.sum', 'go.work'].includes(name)) return 'go'
  if (name === 'pyproject.toml' || name === 'pipfile' || name.startsWith('requirements')) return 'python'
  if (['bun.lock', 'bun.lockb', 'bunfig.toml'].includes(name)) return 'bun'
  if (name.startsWith('pnpm-') || name === '.pnpmfile.cjs') return 'pnpm'
  if (name === 'yarn.lock' || name.startsWith('.yarnrc')) return 'yarn'
  if (name === 'package.json') return 'nodejs'
  if (name === 'package-lock.json') return 'npm'
  if (name === 'tsconfig.json' || name.startsWith('tsconfig.')) return 'typescript'
  if (name === 'jsconfig.json' || name.startsWith('jsconfig.')) return 'javascript'
  if (['.gitignore', '.gitattributes', '.gitmodules', '.gitconfig'].includes(name)) return 'git'
  if (name === '.editorconfig') return 'editorconfig'
  if (name.startsWith('.env')) return 'settings'
  if (name.startsWith('.prettier') || name.startsWith('prettier.config.')) return 'prettier'
  if (name.startsWith('.eslint') || name.startsWith('eslint.config.')) return 'eslint'
  if (name.startsWith('biome.json')) return 'biome'
  if (name.startsWith('.babel') || name.startsWith('babel.config.')) return 'babel'
  if (name.startsWith('.stylelint') || name.startsWith('stylelint.config.')) return 'stylelint'
  if (name.startsWith('vite.config.')) return 'vite'
  if (name.startsWith('vitest.config.') || name.startsWith('vitest.workspace.')) return 'vitest'
  if (name.startsWith('webpack.')) return 'webpack'
  if (name.startsWith('rollup.config.')) return 'rollup'
  if (name.startsWith('next.config.') || name === 'next-env.d.ts') return 'next'
  if (name.startsWith('nuxt.config.') || name === '.nuxtrc') return 'nuxt'
  if (name.startsWith('astro.config.')) return 'astro'
  if (name === 'angular.json' || name.endsWith('.component.ts')) return 'angular'
  if (name === 'nest-cli.json') return 'nest'
  if (name.startsWith('tailwind.config.')) return 'tailwindcss'
  if (name.startsWith('svelte.config.')) return 'svelte'
  if (name.startsWith('vue.config.')) return 'vue'
  if (name === 'firebase.json' || name === '.firebaserc') return 'firebase'
  if (name === 'supabase.toml') return 'supabase'
  if (name.startsWith('prisma.config.')) return 'prisma'
  if (name === 'turbo.json') return 'turborepo'
  if (name.startsWith('deno.json') || name === 'deno.lock') return 'deno'
  if (name === '.gitlab-ci.yml' || name === '.gitlab-ci.yaml') return 'gitlab'
  if (name === 'kustomization.yaml' || name === 'kustomization.yml') return 'kubernetes'
  if (name === 'chart.yaml' || name === 'values.yaml') return 'helm'
  if (name === 'nginx.conf') return 'nginx'
  if (name === '.nvmrc' || name === '.node-version') return 'nodejs'
  if (['build.gradle', 'settings.gradle', 'gradlew', 'gradlew.bat'].includes(name)) return 'gradle'
  if (name.includes('.stories.') || name.includes('.story.')) return 'storybook'
  if (name === 'gemfile' || name === 'gemfile.lock') return 'ruby'
  if (name === 'pom.xml') return 'java'

  const extension = name.includes('.') ? name.split('.').at(-1) ?? '' : ''
  if (extension === 'rs') return 'rust'
  if (['js', 'mjs', 'cjs'].includes(extension)) return 'javascript'
  if (['ts', 'mts', 'cts'].includes(extension)) return 'typescript'
  if (['jsx', 'tsx'].includes(extension)) return 'react'
  if (['py', 'pyi', 'pyw'].includes(extension)) return 'python'
  if (extension === 'go') return 'go'
  if (['c', 'h', 'm'].includes(extension)) return 'c'
  if (['cc', 'cpp', 'cxx', 'hh', 'hpp', 'hxx', 'mm'].includes(extension)) return 'cpp'
  if (extension === 'cs') return 'csharp'
  if (extension === 'swift') return 'swift'
  if (['kt', 'kts'].includes(extension)) return 'kotlin'
  if (['java', 'class'].includes(extension)) return 'java'
  if (extension === 'rb') return 'ruby'
  if (extension === 'php') return 'php'
  if (['html', 'htm'].includes(extension)) return 'html'
  if (['css', 'less'].includes(extension)) return 'css'
  if (['scss', 'sass'].includes(extension)) return 'sass'
  if (['json', 'jsonc', 'jsonl'].includes(extension)) return 'json'
  if (['yaml', 'yml'].includes(extension)) return 'yaml'
  if (['toml', 'ini', 'cfg', 'conf', 'config'].includes(extension)) return 'settings'
  if (['xml', 'xsl', 'plist'].includes(extension)) return 'xml'
  if (['md', 'mdx', 'markdown'].includes(extension)) return 'markdown'
  if (['sh', 'bash', 'zsh', 'fish'].includes(extension)) return 'console'
  if (['ps1', 'psm1'].includes(extension)) return 'powershell'
  if (['sql', 'db', 'sqlite', 'sqlite3', 'csv', 'xls', 'xlsx'].includes(extension)) return 'database'
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'ico', 'tiff'].includes(extension)) return 'image'
  if (extension === 'svg') return 'svg'
  if (extension === 'pdf') return 'pdf'
  if (['mp3', 'wav', 'flac', 'ogg', 'm4a'].includes(extension)) return 'audio'
  if (['mp4', 'mov', 'avi', 'webm', 'mkv'].includes(extension)) return 'video'
  if (['zip', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'tar', 'jar'].includes(extension)) return 'zip'
  if (['wasm', 'wat'].includes(extension)) return 'webassembly'
  if (['svelte', 'vue', 'lua', 'dart', 'astro', 'prisma', 'xaml', 'zig', 'nix', 'proto'].includes(extension)) return extension as FileTypeIconName
  if (['tf', 'tfvars'].includes(extension)) return 'terraform'
  if (['graphql', 'gql'].includes(extension)) return 'graphql'
  if (['coffee', 'cson'].includes(extension)) return 'coffee'
  if (extension === 'cr') return 'crystal'
  if (['ex', 'exs'].includes(extension)) return 'elixir'
  if (extension === 'elm') return 'elm'
  if (['erl', 'hrl'].includes(extension)) return 'erlang'
  if (['clj', 'cljs', 'cljc', 'edn'].includes(extension)) return 'clojure'
  if (['hs', 'lhs'].includes(extension)) return 'haskell'
  if (['hx', 'hxml'].includes(extension)) return 'haxe'
  if (['jinja', 'jinja2', 'j2'].includes(extension)) return 'jinja'
  if (extension === 'jl') return 'julia'
  if (['ml', 'mli'].includes(extension)) return 'ocaml'
  if (['pl', 'pm'].includes(extension)) return 'perl'
  if (['pug', 'jade'].includes(extension)) return 'pug'
  if (['scala', 'sbt', 'sc'].includes(extension)) return 'scala'
  if (extension === 'sol') return 'solidity'
  if (['tex', 'sty', 'cls'].includes(extension)) return 'tex'
  if (['diff', 'patch'].includes(extension)) return 'diff'
  if (['exe', 'dll', 'so', 'dylib'].includes(extension)) return 'exe'
  if (extension === 'lock') return 'lock'
  return 'file'
}

const PROVIDER_ICONS: Record<ProviderKind, string> = {
  amp: iconAsset('provider-amp.svg'),
  claude: iconAsset('provider-claude.svg'),
  codex: iconAsset('provider-openai.svg'),
  cursor: iconAsset('provider-cursor.svg'),
  deepSeek: iconAsset('provider-deepseek.svg'),
  fx: iconAsset('provider-fx.svg'),
  openCode: iconAsset('provider-opencode.svg'),
  grok: iconAsset('provider-grok.svg'),
  kimi: iconAsset('provider-kimi.svg'),
  ohMyPi: iconAsset('provider-ohmypi.svg'),
  pi: iconAsset('provider-pi.svg'),
}

export const PROVIDERS: Array<{
  id: ProviderKind
  name: string
  shortName: string
  command: string
}> = [
  { id: 'amp', name: 'Amp', shortName: 'Amp', command: 'amp' },
  { id: 'claude', name: 'Claude Code', shortName: 'Claude', command: 'claude' },
  { id: 'codex', name: 'Codex CLI', shortName: 'Codex', command: 'codex' },
  { id: 'cursor', name: 'Cursor CLI', shortName: 'Cursor', command: 'cursor-agent' },
  { id: 'deepSeek', name: 'DeepSeek Harness', shortName: 'DeepSeek', command: 'dsh' },
  { id: 'fx', name: 'Fx', shortName: 'Fx', command: 'fx' },
  { id: 'openCode', name: 'OpenCode', shortName: 'OpenCode', command: 'opencode' },
  { id: 'grok', name: 'Grok Build', shortName: 'Grok', command: 'grok' },
  { id: 'kimi', name: 'Kimi Code', shortName: 'Kimi', command: 'kimi' },
  { id: 'ohMyPi', name: 'Oh My Pi', shortName: 'Oh My Pi', command: 'omp' },
  { id: 'pi', name: 'Pi', shortName: 'Pi', command: 'pi' },
]

export function providerMeta(provider: ProviderKind) {
  return PROVIDERS.find((candidate) => candidate.id === provider) ?? PROVIDERS[2]!
}

export function ProviderIcon({
  provider,
  className,
  label,
}: {
  provider: ProviderKind
  className?: string
  label?: string
}) {
  return (
    <span
      aria-hidden={label ? undefined : true}
      aria-label={label}
      className={`inline-grid size-4 shrink-0 place-items-center ${providerColor(provider)} ${className ?? ''}`}
      role={label ? 'img' : undefined}
    >
      <span
        aria-hidden="true"
        className="size-full bg-current"
        style={{
          maskImage: `url(${PROVIDER_ICONS[provider]})`,
          maskPosition: 'center',
          maskRepeat: 'no-repeat',
          maskSize: 'contain',
        }}
      />
    </span>
  )
}

function providerColor(provider: ProviderKind) {
  if (provider === 'amp') return 'text-[#f34e3f]'
  if (provider === 'claude') return 'text-[#d97757]'
  if (provider === 'deepSeek') return 'text-[#4d6bfe]'
  return 'text-[#34363b] dark:text-[#f3f3f3]'
}

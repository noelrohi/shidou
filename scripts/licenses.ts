#!/usr/bin/env bun

import { $ } from 'bun'
import { copyFile, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const projectRoot = resolve(import.meta.dir, '..')
const check = process.argv.includes('--check')
const allowedJavaScriptLicenses = [
  '0BSD',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'BlueOak-1.0.0',
  'CC-BY-4.0',
  'ISC',
  'MIT',
  'MPL-2.0',
  'OFL-1.1',
  'Python-2.0',
  'Unlicense',
].join(';')

const outputs = {
  rust: 'licenses/THIRD_PARTY_RUST_LICENSES.html',
  web: 'apps/web/public/THIRD_PARTY_LICENSES.txt',
  webGpl: 'apps/web/public/LICENSE.txt',
  webNotices: 'apps/web/public/THIRD_PARTY_NOTICES.md',
  website: 'website/public/THIRD_PARTY_LICENSES.txt',
  websiteGpl: 'website/public/LICENSE.txt',
  websiteNotices: 'website/public/THIRD_PARTY_NOTICES.md',
} as const

const outputRoot = check
  ? await mkdtemp(join(tmpdir(), 'shidou-license-check-'))
  : projectRoot

for (const relative of Object.values(outputs)) {
  await mkdir(resolve(outputRoot, relative, '..'), { recursive: true })
}

process.chdir(projectRoot)

await $`cargo about generate licenses/about.hbs --workspace --locked --fail --output-file ${resolve(outputRoot, outputs.rust)}`
const rustReportPath = resolve(outputRoot, outputs.rust)
const rustReport = await readFile(rustReportPath, 'utf8')
await writeFile(
  rustReportPath,
  `${rustReport.replaceAll('\r\n', '\n').replace(/[ \t]+$/gm, '').trimEnd()}\n`,
)

async function generateJavaScriptLicenses(workspace: string, output: string) {
  await $`license-checker-rseidelsohn --start ${workspace} --production --excludePrivatePackages --onlyAllow ${allowedJavaScriptLicenses} --plainVertical --out ${resolve(outputRoot, output)}`
}

await generateJavaScriptLicenses('apps/web', outputs.web)
await generateJavaScriptLicenses('website', outputs.website)
await copyFile('LICENSE', resolve(outputRoot, outputs.webGpl))
await copyFile('THIRD_PARTY_NOTICES.md', resolve(outputRoot, outputs.webNotices))
await copyFile('LICENSE', resolve(outputRoot, outputs.websiteGpl))
await copyFile(
  'THIRD_PARTY_NOTICES.md',
  resolve(outputRoot, outputs.websiteNotices),
)

if (check) {
  const stale: string[] = []
  for (const relative of Object.values(outputs)) {
    const [expected, actual] = await Promise.all([
      readFile(resolve(projectRoot, relative)),
      readFile(resolve(outputRoot, relative)),
    ])
    if (!expected.equals(actual)) stale.push(relative)
  }
  if (stale.length) {
    throw new Error(`Generated license reports are stale: ${stale.join(', ')}`)
  }
  console.log('License reports are current.')
}

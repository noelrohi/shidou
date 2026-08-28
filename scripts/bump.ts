#!/usr/bin/env bun

import { $ } from "bun";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { extractReleaseNotes } from "./changelog";
import { derivedBuildNumber, findPackageVersion, parseVersion } from "./version";

const projectRoot = resolve(import.meta.dir, "..");
const manifestPath = join(projectRoot, "Cargo.toml");
const iosProjectYmlPath = join(projectRoot, "apps/ios/project.yml");

const help = `Bump the release version in Cargo.toml and regenerate what derives from it.

Usage:
  bun run bump <version|major|minor|patch>

The version in Cargo.toml is the single source of truth, and two generated
artifacts embed it: Cargo.lock's workspace entry and the Rust license report
(licenses/THIRD_PARTY_RUST_LICENSES.html, which lists "shidou <version>").
Bumping by hand leaves both stale, and CI's licenses:check fails on the next
push. This rewrites the manifest, refreshes the lock, and regenerates every
license report in one step.

Arguments:
  major | minor | patch    Increment that field of the current version
  <version>                An explicit version, e.g. 0.3.0 or 0.3.0-beta.1

Options:
  --help                   Show this help

Afterwards, add a "## [<version>]" section to CHANGELOG.md (Sparkle serves it
as the update's release notes) and run \`bun run release\`.
`;

const { values, positionals } = parseArgs({
  args: Bun.argv.slice(2),
  options: { help: { type: "boolean", short: "h" } },
  allowPositionals: true,
  strict: true,
});

if (values.help) {
  console.log(help);
  process.exit(0);
}

if (positionals.length !== 1) {
  throw new Error(
    "Pass exactly one version or bump level. See `bun run bump --help`.",
  );
}

function logStep(message: string): void {
  console.log(`\n==> ${message}`);
}

function nextVersion(current: string, requested: string): string {
  const [major, minor, patch] = parseVersion(current);
  switch (requested) {
    case "major":
      return `${major + 1}.0.0`;
    case "minor":
      return `${major}.${minor + 1}.0`;
    case "patch":
      return `${major}.${minor}.${patch + 1}`;
    default:
      return requested;
  }
}

process.chdir(projectRoot);

const manifest = await readFile(manifestPath, "utf8");
const current = findPackageVersion(manifest);
const version = nextVersion(current.version, positionals[0]!);
const target = parseVersion(version);
const source = parseVersion(current.version);

if (version === current.version) {
  throw new Error(`Cargo.toml is already at ${version}.`);
}
// Only the numeric triple is compared, so promoting a prerelease
// (0.2.6-beta.1 → 0.2.6) passes. Prerelease ordering is the release script's
// problem — it refuses to publish one at all. This guard is here to catch a
// typo that would move the version backwards.
for (let field = 0; field < 3; field++) {
  if (target[field]! > source[field]!) break;
  if (target[field]! < source[field]!) {
    throw new Error(
      `${version} is older than the current ${current.version}. ` +
        "Sparkle compares build numbers, so versions only move forward.",
    );
  }
}

if (!Bun.which("cargo-about")) {
  throw new Error(
    "cargo-about is not in PATH; the Rust license report cannot be " +
      "regenerated. Install it with `cargo install cargo-about --locked`.",
  );
}

logStep(`Setting the version to ${version} (was ${current.version})`);
const lines = manifest.split("\n");
lines[current.line] = `version = "${version}"`;
await writeFile(manifestPath, lines.join("\n"));

// --workspace touches only the workspace members, so the release bump cannot
// quietly pull in new versions of third-party dependencies.
logStep("Refreshing Cargo.lock");
await $`cargo update --workspace`;

// The iOS build settings mirror the Cargo version so a manual Xcode archive
// carries the right values; scripts/ios-release.ts overrides them the same
// way when archiving from the command line.
logStep("Syncing apps/ios/project.yml");
const iosProject = await readFile(iosProjectYmlPath, "utf8");
const syncedIosProject = iosProject
  .replace(/^        MARKETING_VERSION: .*$/m, `        MARKETING_VERSION: ${version}`)
  .replace(
    /^        CURRENT_PROJECT_VERSION: .*$/m,
    `        CURRENT_PROJECT_VERSION: ${derivedBuildNumber(version)}`,
  );
// A no-match replace is a silent no-op, which would ship a stale iOS
// version — fail instead of letting project.yml drift from Cargo.toml.
if (syncedIosProject === iosProject) {
  throw new Error(
    "apps/ios/project.yml has no MARKETING_VERSION/CURRENT_PROJECT_VERSION " +
      "pair to sync; the file drifted from what bump expects.",
  );
}
await writeFile(iosProjectYmlPath, syncedIosProject);
if (Bun.which("xcodegen")) {
  logStep("Regenerating the Xcode project");
  await $`cd apps/ios && xcodegen generate`;
} else {
  console.log(
    "xcodegen is not installed; run `xcodegen generate` in apps/ios before " +
      "the next iOS build.",
  );
}

logStep("Regenerating the license reports");
// `bun run`, not `bun scripts/licenses.ts`: the license reports shell out to
// license-checker-rseidelsohn, which only resolves from node_modules/.bin when
// bun puts it on PATH for a package script.
await $`bun run licenses:generate`;

const changelogFile = Bun.file(join(projectRoot, "CHANGELOG.md"));
const notes = (await changelogFile.exists())
  ? extractReleaseNotes(await changelogFile.text(), version)
  : null;

console.log(`\nBumped to ${version}. Commit these together:`);
for (const path of [
  "Cargo.toml",
  "Cargo.lock",
  "apps/ios/project.yml",
  "licenses/THIRD_PARTY_RUST_LICENSES.html",
]) {
  console.log(`  ${path}`);
}
if (!notes) {
  console.log(
    `Next: add a "## [${version}]" section to CHANGELOG.md, commit, and run ` +
      "`bun run release`.",
  );
} else {
  console.log(
    "Next: commit the bump and run `bun run release`. " +
      `CHANGELOG.md already has notes for ${version}.`,
  );
}

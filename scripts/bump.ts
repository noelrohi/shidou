#!/usr/bin/env bun

import { $ } from "bun";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { extractReleaseNotes } from "./changelog";

const projectRoot = resolve(import.meta.dir, "..");
const manifestPath = join(projectRoot, "Cargo.toml");

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

/** The `version` line of the root `[package]` table. Later tables carry their
 *  own `version` keys (dependencies, metadata), so the search stops at the
 *  next table header rather than taking the first match in the file. */
function findPackageVersion(manifest: string): { line: number; version: string } {
  const lines = manifest.split("\n");
  let inPackage = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    if (/^\s*\[/.test(line)) {
      inPackage = /^\s*\[package\]\s*$/.test(line);
      continue;
    }
    if (!inPackage) continue;
    const match = line.match(/^\s*version\s*=\s*"([^"]+)"\s*$/);
    if (match?.[1]) return { line: i, version: match[1] };
  }
  throw new Error("No `version` key in the root [package] table of Cargo.toml.");
}

// The same shape scripts/release.ts derives a CFBundleVersion from: three
// fields of at most three digits, plus an optional prerelease tag.
const versionPattern = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:-([0-9A-Za-z.-]+))?$/;

function parseVersion(version: string): [number, number, number] {
  const match = version.match(versionPattern);
  if (!match) {
    throw new Error(
      `"${version}" is not a version this project can release. Use ` +
        "major.minor.patch, each at most three digits, with an optional " +
        "-prerelease suffix.",
    );
  }
  return [Number(match[1]), Number(match[2]), Number(match[3])];
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

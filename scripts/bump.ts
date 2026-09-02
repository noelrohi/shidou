#!/usr/bin/env bun

import { $ } from "bun";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import {
  findIosVersion,
  findPackageVersion,
  nextVersion,
  setIosVersion,
} from "./version";

const projectRoot = resolve(import.meta.dir, "..");
const manifestPath = join(projectRoot, "Cargo.toml");
const iosProjectYmlPath = join(projectRoot, "apps/ios/project.yml");

const help = `Bump one app's marketing version and regenerate what derives from it.

Usage:
  bun run bump --app <desktop|ios> <version|major|minor|patch>

Desktop and iOS have separate release lines (docs/adr/0004), so each app has
its own version and this bumps exactly one:

  desktop   Cargo.toml is the source of truth. Two generated artifacts embed
            it: Cargo.lock's workspace entry and the Rust license report
            (licenses/THIRD_PARTY_RUST_LICENSES.html). This rewrites the
            manifest, refreshes the lock, and regenerates every license
            report in one step so CI's licenses:check stays green.
  ios       apps/ios/project.yml's MARKETING_VERSION is the source of truth;
            CURRENT_PROJECT_VERSION is derived from it. The Xcode project is
            regenerated when xcodegen is installed.

Arguments:
  major | minor | patch    Increment that field of the current version
  <version>                An explicit version, e.g. 0.3.0 or 0.3.0-beta.1

Options:
  --app <desktop|ios>      Which app to bump (required)
  --help                   Show this help

\`bun run ship\` runs this for you and writes the changelog from the pending
Change Notes; call it directly only for a hand-made release commit.
`;

function logStep(message: string): void {
  console.log(`\n==> ${message}`);
}

/** Rewrite Cargo.toml and everything that embeds its version. Returns the
 *  files to commit together. */
export async function bumpDesktop(requested: string): Promise<{
  version: string;
  previous: string;
  files: string[];
}> {
  process.chdir(projectRoot);
  const manifest = await readFile(manifestPath, "utf8");
  const current = findPackageVersion(manifest);
  const version = nextVersion(current.version, requested);

  if (!Bun.which("cargo-about")) {
    throw new Error(
      "cargo-about is not in PATH; the Rust license report cannot be " +
        "regenerated. Install it with `cargo install cargo-about --locked`.",
    );
  }

  logStep(`Setting the desktop version to ${version} (was ${current.version})`);
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

  return {
    version,
    previous: current.version,
    files: ["Cargo.toml", "Cargo.lock", "licenses/THIRD_PARTY_RUST_LICENSES.html"],
  };
}

/** Rewrite apps/ios/project.yml and regenerate the Xcode project. */
export async function bumpIos(requested: string): Promise<{
  version: string;
  previous: string;
  files: string[];
}> {
  process.chdir(projectRoot);
  const projectYml = await readFile(iosProjectYmlPath, "utf8");
  const current = findIosVersion(projectYml);
  const version = nextVersion(current.version, requested);

  logStep(`Setting the iOS version to ${version} (was ${current.version})`);
  await writeFile(iosProjectYmlPath, setIosVersion(projectYml, version));
  if (Bun.which("xcodegen")) {
    logStep("Regenerating the Xcode project");
    await $`cd apps/ios && xcodegen generate`;
  } else {
    console.log(
      "xcodegen is not installed; run `xcodegen generate` in apps/ios before " +
        "the next iOS build.",
    );
  }
  return { version, previous: current.version, files: ["apps/ios/project.yml"] };
}

if (import.meta.main) {
  const { values, positionals } = parseArgs({
    args: Bun.argv.slice(2),
    options: { app: { type: "string" }, help: { type: "boolean", short: "h" } },
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
  const app = values.app;
  if (app !== "desktop" && app !== "ios") {
    throw new Error("Pass --app desktop or --app ios. See `bun run bump --help`.");
  }

  const result = app === "desktop"
    ? await bumpDesktop(positionals[0]!)
    : await bumpIos(positionals[0]!);
  console.log(`\nBumped ${app} to ${result.version}. Commit these together:`);
  for (const path of result.files) console.log(`  ${path}`);
  console.log(`Next: \`bun run ship ${app}\` writes the changelog and publishes.`);
}

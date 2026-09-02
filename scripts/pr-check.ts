/** Pull request gate: every PR that can reach `master` names the apps it
 *  affects with `app:*` labels, and every user-visible change carries a
 *  Change Note with wording for each labeled Client. CI runs this on the
 *  pull request; the rules are pure so they can be tested and so the same
 *  file documents them. See RELEASING.md. */

import { $ } from "bun";
import { readFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import {
  type ChangeNote,
  type NoteApp,
  changesDirectoryName,
  noteApps,
  parseChangeNote,
} from "./changes";

/** Every app a PR can be labeled with. Website deploys never carry notes. */
export const apps = ["desktop", "ios", "browser", "website"] as const;
export type App = (typeof apps)[number];

export const appLabel = (app: App) => `app:${app}` as const;
/** No user-visible change ships from this PR: docs, CI, tests, refactors. */
export const noReleaseLabel = "no-release";
/** The wire protocol version changes; old and new clients will not connect. */
export const protocolBreakingLabel = "protocol:breaking";

export const protocolVersionFile = "crates/shidou-protocol/src/protocol.rs";

/** Paths that belong to exactly one app. A change here without that app's
 *  label fails the check. Shared code (crates/shidou-core, shidou-protocol,
 *  packages/shidou-client, bun.lock) is deliberately absent: the author
 *  knows which Clients a shared change reaches, so it only warns below. */
export const strictPaths: Record<App, string[]> = {
  desktop: ["src/", "resources/", "crates/shidou-client/", "crates/shidou-daemon/"],
  ios: ["apps/ios/"],
  browser: ["apps/web/"],
  website: ["website/"],
};

export const sharedPaths = [
  "crates/shidou-core/",
  "crates/shidou-protocol/",
  "packages/shidou-client/",
  "bun.lock",
];

export type PullRequestFacts = {
  labels: string[];
  /** Paths changed relative to the merge base. */
  changedFiles: string[];
  /** Whether the PR changes the `PROTOCOL_VERSION` constant. */
  protocolVersionChanged: boolean;
  /** Change Notes added or modified by the PR, already parsed. A release
   *  PR only marks notes shipped, so `added` separates a new note from an
   *  edit to an existing one. */
  notes: Array<{ note: ChangeNote; added: boolean }>;
};

export type Verdict = { errors: string[]; warnings: string[] };

export function appsFromLabels(labels: string[]): App[] {
  return apps.filter((app) => labels.includes(appLabel(app)));
}

export function appsFromPaths(
  files: string[],
  paths: Record<App, string[]> = strictPaths,
): App[] {
  return apps.filter((app) =>
    files.some((file) => paths[app].some((prefix) => file.startsWith(prefix))),
  );
}

export function evaluatePullRequest(facts: PullRequestFacts): Verdict {
  const errors: string[] = [];
  const warnings: string[] = [];
  const labeled = appsFromLabels(facts.labels);
  const noRelease = facts.labels.includes(noReleaseLabel);

  if (labeled.length === 0 && !noRelease) {
    errors.push(
      `Label the pull request with the apps it affects (${apps
        .map(appLabel)
        .join(", ")}) or with \`${noReleaseLabel}\` if nothing ships from it.`,
    );
  }

  // Strict paths: an app that clearly changed must be labeled. Extra labels
  // are fine; the author may know about reach the path map cannot see.
  for (const app of appsFromPaths(facts.changedFiles)) {
    if (!labeled.includes(app)) {
      const hit = facts.changedFiles.find((file) =>
        strictPaths[app].some((prefix) => file.startsWith(prefix)),
      );
      errors.push(
        `\`${hit}\` changed, so the pull request needs the \`${appLabel(app)}\` label.`,
      );
    }
  }

  const sharedHit = facts.changedFiles.find((file) =>
    sharedPaths.some((prefix) => file.startsWith(prefix)),
  );
  if (sharedHit) {
    const missing = (["desktop", "ios", "browser"] as const).filter(
      (app) => !labeled.includes(app),
    );
    if (missing.length > 0) {
      warnings.push(
        `\`${sharedHit}\` is shared code; confirm it does not reach ` +
          `${missing.join(", ")} (labels: ${missing.map(appLabel).join(", ")}).`,
      );
    }
  }

  if (facts.protocolVersionChanged) {
    const required = [
      ...(["desktop", "ios", "browser"] as const).map(appLabel),
      protocolBreakingLabel,
    ];
    const missing = required.filter((label) => !facts.labels.includes(label));
    if (missing.length > 0) {
      errors.push(
        `PROTOCOL_VERSION changed, which disconnects every Client on the old ` +
          `version. Add ${missing.map((l) => `\`${l}\``).join(", ")}, and plan to ship ` +
          "Desktop, iOS, and Browser together (prefer a compatible change instead).",
      );
    }
  } else if (facts.labels.includes(protocolBreakingLabel)) {
    warnings.push(
      `\`${protocolBreakingLabel}\` is set, but PROTOCOL_VERSION did not change.`,
    );
  }

  // Notes: with `no-release`, nothing user-visible ships, so a note is a
  // contradiction. Without it, every labeled Client needs wording.
  if (noRelease) {
    const added = facts.notes.filter((entry) => entry.added);
    if (added.length > 0) {
      errors.push(
        `\`${noReleaseLabel}\` says nothing user-visible ships, but the pull request ` +
          `adds ${added.map((n) => `${changesDirectoryName}/${n.note.slug}.md`).join(", ")}. ` +
          "Drop the label or the note.",
      );
    }
  } else {
    for (const app of labeled) {
      if (app === "website") continue;
      const covered = facts.notes.some(({ note }) => note.wording[app as NoteApp]);
      if (!covered) {
        errors.push(
          `\`${appLabel(app)}\` is set, but no Change Note in this pull request has ` +
            `\`${app}:\` wording. Add one under ${changesDirectoryName}/ (see RELEASING.md), ` +
            `or label the pull request \`${noReleaseLabel}\` if the change is not user-visible.`,
        );
      }
    }
    for (const { note } of facts.notes) {
      for (const app of noteApps) {
        if (note.wording[app] && !labeled.includes(app)) {
          errors.push(
            `${changesDirectoryName}/${note.slug}.md has \`${app}:\` wording, but the pull ` +
              `request is not labeled \`${appLabel(app)}\`.`,
          );
        }
      }
    }
  }

  return { errors, warnings };
}

/** Whether a unified diff of the protocol file touches the version constant. */
export function protocolVersionChangedIn(diff: string): boolean {
  return /^[+-]\s*pub const PROTOCOL_VERSION\b/m.test(diff);
}

async function main(): Promise<void> {
  const projectRoot = resolve(import.meta.dir, "..");
  const eventPath = process.env.GITHUB_EVENT_PATH;
  const baseSha = process.env.PR_BASE_SHA;
  const headSha = process.env.PR_HEAD_SHA;
  if (!eventPath || !baseSha || !headSha) {
    throw new Error(
      "Run from the pull-request workflow: GITHUB_EVENT_PATH, PR_BASE_SHA, and " +
        "PR_HEAD_SHA must be set.",
    );
  }
  const event = JSON.parse(await readFile(eventPath, "utf8")) as {
    pull_request?: { labels?: Array<{ name: string }> };
  };
  const labels = event.pull_request?.labels?.map((label) => label.name) ?? [];

  process.chdir(projectRoot);
  const range = `${baseSha}...${headSha}`;
  const changedFiles = (await $`git diff --name-only ${range}`.text())
    .split("\n")
    .filter(Boolean);
  const protocolDiff = changedFiles.includes(protocolVersionFile)
    ? await $`git diff ${range} -- ${protocolVersionFile}`.text()
    : "";

  const notes: PullRequestFacts["notes"] = [];
  const noteProblems: string[] = [];
  for (const file of changedFiles) {
    if (!file.startsWith(`${changesDirectoryName}/`) || !file.endsWith(".md")) continue;
    if (file === `${changesDirectoryName}/README.md`) continue;
    // A note deleted by this PR (fully shipped) is not a note to check.
    const status = (await $`git diff --name-status ${range} -- ${file}`.text()).trim();
    if (status.startsWith("D")) continue;
    const source = await readFile(join(projectRoot, file), "utf8");
    try {
      notes.push({
        note: parseChangeNote(basename(file, ".md"), source),
        added: status.startsWith("A"),
      });
    } catch (error) {
      noteProblems.push(`${file}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  const verdict = evaluatePullRequest({
    labels,
    changedFiles,
    protocolVersionChanged: protocolVersionChangedIn(protocolDiff),
    notes,
  });
  verdict.errors.unshift(...noteProblems);

  for (const warning of verdict.warnings) console.log(`::warning::${warning}`);
  for (const error of verdict.errors) console.log(`::error::${error}`);
  if (verdict.errors.length > 0) {
    console.log(`\n${verdict.errors.length} problem(s). Labels: ${labels.join(", ") || "none"}.`);
    process.exit(1);
  }
  console.log(
    `Labels ${labels.join(", ") || "none"} agree with the changed files` +
      (notes.length > 0 ? ` and ${notes.length} change note(s).` : "."),
  );
}

if (import.meta.main) {
  await main();
}

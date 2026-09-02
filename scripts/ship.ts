#!/usr/bin/env bun

/** The one front door for shipping Shidou. Each Delivery Channel keeps its
 *  own command underneath (`bun run release`, `bun run ios-release`, the
 *  deploy-workers workflow); this decides which channel a request means,
 *  prints the plan, and drives that channel from a clean `master` to a
 *  Delivery Record. See RELEASING.md and docs/adr/0004. */

import { $ } from "bun";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { bumpDesktop, bumpIos } from "./bump";
import {
  type ChangeNote,
  type NoteApp,
  changelogBullets,
  changesDirectoryName,
  prependChangelogSection,
  readChangeNotes,
  shipChangeNotes,
} from "./changes";
import {
  type Channel,
  type ChannelStatus,
  channelNames,
  channelStatus,
  channels,
  describeStatus,
  isAffected,
  tagPrefix,
} from "./channels";
import { appLabel, noReleaseLabel, protocolVersionFile } from "./pr-check";
import { findIosVersion, findPackageVersion, nextVersion } from "./version";

const projectRoot = resolve(import.meta.dir, "..");
const masterRef = "origin/master";

const help = `Ship Shidou through one Delivery Channel.

Usage:
  bun run ship                       Show every channel; ship the one that changed
  bun run ship <channel> [options]   Ship that channel
  bun run ship status                Show every channel and exit

Channels: desktop, ios, browser, website

Desktop and iOS ship on request. Desktop bumps its version. A routine iOS
TestFlight upload keeps its marketing version and increments its build number;
--app-store-version changes the marketing version for an App Store update.
Both write pending Change Notes, land a release pull request, publish, and
record the delivered commit. iOS records include both values:
ios/v<marketing-version>-build.<build-number>.

Browser and website deploy automatically when a pull request merges to
master; here they only report what master holds beyond the last successful
deployment. --force redeploys master.

Options:
  --minor, --major          Bump that field instead of the patch (Desktop)
  --version <x.y.z>         Use this exact Desktop version instead of bumping
  --app-store-version <x.y.z>
                            Change the iOS marketing version for an App Store
                            update. Routine TestFlight uploads omit this.
  --force                   Rebuild or redeploy already shipped code. Never
                            bypasses the clean-tree, test, note, or protocol
                            checks.
  --force-protocol          Ship despite a wire protocol version that differs
                            from the last Desktop Release. Use it once, for
                            Desktop, when a breaking change is intended; then
                            ship iOS and Browser right after.
  --allow-empty-notes       Release with no pending Change Notes
  --dry-run                 Print the plan and stop before changing anything
  --help                    Show this help

With no channel, exactly one affected channel is shipped; several are listed
and asked about; none exits with nothing to do. Set CI=1 to make the several
case fail instead of asking.
`;

const { values, positionals } = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    "allow-empty-notes": { type: "boolean" },
    "app-store-version": { type: "string" },
    "dry-run": { type: "boolean" },
    force: { type: "boolean" },
    "force-protocol": { type: "boolean" },
    help: { type: "boolean", short: "h" },
    major: { type: "boolean" },
    minor: { type: "boolean" },
    version: { type: "string" },
  },
  allowPositionals: true,
  strict: true,
});

if (values.help) {
  console.log(help);
  process.exit(0);
}
if (positionals.length > 1) {
  throw new Error("Pass at most one channel. See `bun run ship --help`.");
}
if ([values.major, values.minor, values.version].filter(Boolean).length > 1) {
  throw new Error("Use one of --major, --minor, or --version.");
}
if (values["app-store-version"] && (values.major || values.minor || values.version)) {
  throw new Error("--app-store-version cannot be combined with Desktop version options.");
}

const options = {
  version: values.version,
  appStoreVersion: values["app-store-version"],
  level: values.version ?? (values.major ? "major" : values.minor ? "minor" : "patch"),
  force: values.force ?? false,
  forceProtocol: values["force-protocol"] ?? false,
  allowEmptyNotes: values["allow-empty-notes"] ?? false,
  dryRun: values["dry-run"] ?? false,
};

function logStep(message: string): void {
  console.log(`\n==> ${message}`);
}

function isChannel(value: string): value is Channel {
  return (channels as readonly string[]).includes(value);
}

async function git(...args: string[]): Promise<string> {
  return (await $`git ${args}`.quiet().text()).trim();
}

async function fileAt(ref: string, path: string): Promise<string | null> {
  const result = await $`git show ${`${ref}:${path}`}`.quiet().nothrow();
  return result.exitCode === 0 ? result.stdout.toString() : null;
}

async function protocolVersionAt(ref: string): Promise<number | null> {
  const source = await fileAt(ref, protocolVersionFile);
  const match = source?.match(/pub const PROTOCOL_VERSION:\s*u32\s*=\s*(\d+)/);
  return match ? Number(match[1]) : null;
}

async function tagExists(tag: string): Promise<boolean> {
  return (await $`git rev-parse -q --verify ${`refs/tags/${tag}`}`.quiet().nothrow()).exitCode === 0;
}

/** Everything a release needs before it starts: gh signed in, master fetched,
 *  a clean working tree that sits exactly on origin/master. */
async function preflight(): Promise<void> {
  process.chdir(projectRoot);
  if (!Bun.which("gh")) throw new Error("GitHub CLI (gh) is required.");
  if ((await $`gh auth status`.quiet().nothrow()).exitCode !== 0) {
    throw new Error("gh is not signed in; run `gh auth login`.");
  }
  const fetched = await $`git fetch --quiet --tags --prune origin`.nothrow();
  if (fetched.exitCode !== 0) {
    throw new Error(
      `Could not fetch origin, so master and the Delivery Records may be stale:\n${fetched.stderr.toString().trim()}`,
    );
  }
}

async function requireCleanMaster(): Promise<string> {
  const dirty = await git("status", "--porcelain");
  if (dirty) {
    throw new Error(
      "The working tree has uncommitted changes. Ship only committed, pushed code:\n" + dirty,
    );
  }
  const branch = await git("branch", "--show-current");
  const head = await git("rev-parse", "HEAD");
  const master = await git("rev-parse", masterRef);
  if (branch !== "master" || head !== master) {
    throw new Error(
      `Releases start from master at ${masterRef} (${master.slice(0, 10)}). ` +
        `You are on ${branch || "a detached HEAD"} at ${head.slice(0, 10)}. ` +
        "Run `git checkout master && git pull --ff-only` first.",
    );
  }
  return master;
}

async function allStatuses(): Promise<ChannelStatus[]> {
  const notes = await readChangeNotes(projectRoot);
  const statuses: ChannelStatus[] = [];
  for (const channel of channels) {
    statuses.push(await channelStatus(projectRoot, channel, masterRef, notes));
  }
  return statuses;
}

function printStatuses(statuses: ChannelStatus[]): void {
  for (const status of statuses) {
    console.log(describeStatus(status).join("\n"));
    console.log();
  }
}

/** Refuse a Client release whose wire protocol no longer matches the Daemon
 *  users have, unless the caller took responsibility with --force-protocol. */
async function checkProtocol(channel: Channel, master: string): Promise<void> {
  const desktopTag = (await channelStatus(projectRoot, "desktop", masterRef)).record;
  if (!desktopTag) return;
  const shipped = await protocolVersionAt(desktopTag.sha);
  const current = await protocolVersionAt(master);
  if (shipped === null || current === null || shipped === current) return;
  const detail =
    `PROTOCOL_VERSION is ${current} on master but ${shipped} in ${desktopTag.label}, ` +
    "the Daemon users run.";
  if (options.forceProtocol) {
    console.warn(
      `\nWarning: ${detail} Shipping anyway (--force-protocol); ` +
        (channel === "desktop"
          ? "ship iOS and Browser right after, since they stop connecting until they match."
          : "this Client will not connect to Daemons that have not updated."),
    );
    return;
  }
  throw new Error(
    `${detail} ${
      channel === "desktop"
        ? "A Desktop Release with a new protocol disconnects every iOS and Browser Client " +
          "until they ship too. If that is intended, pass --force-protocol and ship iOS and " +
          "Browser immediately after."
        : `${channelNames[channel]} would not connect to the shipped Daemon. Ship Desktop ` +
          "first (with --force-protocol), or pass --force-protocol here if you know better."
    }`,
  );
}

type ReleasePlan = {
  channel: "desktop" | "ios";
  /** Desktop version, or iOS `<marketing-version>-build.<build-number>`. */
  version: string;
  /** Version stamped into the app. Equal to version for Desktop. */
  appVersion: string;
  buildNumber?: string;
  previous: string;
  notes: ChangeNote[];
  master: string;
  resume: boolean;
};

const changelogPath: Record<"desktop" | "ios", string> = {
  desktop: "CHANGELOG.md",
  ios: "CHANGELOG-ios.md",
};

async function versionAt(channel: "desktop" | "ios", ref: string): Promise<string> {
  if (channel === "desktop") {
    return findPackageVersion((await fileAt(ref, "Cargo.toml")) ?? "").version;
  }
  return findIosVersion((await fileAt(ref, "apps/ios/project.yml")) ?? "").version;
}

function changelogHasSection(changelog: string | null, version: string): boolean {
  return !!changelog && new RegExp(`^## \\[${version.replace(/\./g, "\\.")}\\]`, "m").test(changelog);
}

/** Resolve the next globally increasing TestFlight build number without
 *  archiving. The iOS release command owns ASC authentication and selection. */
async function resolveIosBuildNumber(): Promise<string> {
  const output = await $`bun run ios-release --print-next-build-number`.quiet().text();
  const buildNumber = output.trim().split("\n").at(-1) ?? "";
  if (!/^\d+$/.test(buildNumber)) {
    throw new Error(`Could not resolve the next iOS build number: ${output.trim()}`);
  }
  return buildNumber;
}

function pendingIosDelivery(
  changelog: string | null,
  marketingVersion: string,
): { version: string; buildNumber: string } | null {
  const escaped = marketingVersion.replace(/\./g, "\\.");
  const match = changelog?.match(
    new RegExp(`^## \\[(${escaped}-build\\.(\\d+))\\]`, "m"),
  );
  return match?.[1] && match[2]
    ? { version: match[1], buildNumber: match[2] }
    : null;
}

/** Decide between resuming a release commit already on master and starting
 *  a new one. Desktop versions each release. TestFlight builds keep the iOS
 *  marketing version unless --app-store-version explicitly changes it. */
async function planRelease(
  channel: "desktop" | "ios",
  status: ChannelStatus,
  master: string,
): Promise<ReleasePlan> {
  const masterVersion = await versionAt(channel, masterRef);
  const prefix = tagPrefix[channel]!;
  const changelog = await fileAt(masterRef, changelogPath[channel]);

  if (channel === "ios") {
    const marketingVersion = options.appStoreVersion
      ? nextVersion(masterVersion, options.appStoreVersion)
      : masterVersion;
    const pending = pendingIosDelivery(changelog, marketingVersion);
    if (pending && !(await tagExists(`${prefix}${pending.version}`))) {
      return {
        channel,
        version: pending.version,
        appVersion: marketingVersion,
        buildNumber: pending.buildNumber,
        previous: status.record?.version ?? "none",
        notes: [],
        master,
        resume: true,
      };
    }
    if (status.notes.length === 0 && !options.allowEmptyNotes) {
      throw new Error(
        "No pending Change Notes for iOS Release. Add notes under .changes/, " +
          "or pass --allow-empty-notes for a maintenance TestFlight build.",
      );
    }
    const buildNumber = await resolveIosBuildNumber();
    return {
      channel,
      version: `${marketingVersion}-build.${buildNumber}`,
      appVersion: marketingVersion,
      buildNumber,
      previous: status.record?.version ?? "none",
      notes: status.notes,
      master,
      resume: false,
    };
  }

  if (!(await tagExists(`${prefix}${masterVersion}`)) && changelogHasSection(changelog, masterVersion)) {
    if (options.version && options.version !== masterVersion) {
      throw new Error(
        `master already carries the unshipped release ${masterVersion}; finish it before ` +
          `starting ${options.version}.`,
      );
    }
    return {
      channel,
      version: masterVersion,
      appVersion: masterVersion,
      previous: status.record?.version ?? "none",
      notes: [],
      master,
      resume: true,
    };
  }
  const version = nextVersion(masterVersion, options.level);
  if (status.notes.length === 0 && !options.allowEmptyNotes) {
    throw new Error(
      `No pending Change Notes for ${channelNames[channel]}. Users would see an empty ` +
        "release. Add notes under .changes/, or pass --allow-empty-notes for a " +
        "maintenance release.",
    );
  }
  return {
    channel,
    version,
    appVersion: version,
    previous: masterVersion,
    notes: status.notes,
    master,
    resume: false,
  };
}

function printPlan(plan: ReleasePlan, status: ChannelStatus): void {
  console.log(`\n${channelNames[plan.channel]} plan`);
  console.log(`  version   ${plan.previous} → ${plan.version}${plan.resume ? "  (resuming: release commit already on master)" : ""}`);
  if (plan.buildNumber) {
    console.log(`  app       ${plan.appVersion} (build ${plan.buildNumber})`);
  }
  console.log(`  commit    ${plan.master.slice(0, 10)} (${masterRef})`);
  console.log(`  record    ${status.record ? status.record.label : "none yet"}`);
  if (!plan.resume) {
    console.log(`  notes     ${plan.notes.length === 0 ? "none (maintenance release)" : ""}`);
    for (const line of changelogBullets(plan.notes, plan.channel)) console.log(`    ${line}`);
    if (status.files.length > 0) {
      console.log(`  code      ${status.files.length} changed file(s) since the last record`);
    }
  }
}

/** Open, wait for, and squash-merge the release pull request. Returns the
 *  merge commit on master. */
async function landReleasePullRequest(plan: ReleasePlan): Promise<string> {
  const { channel, version } = plan;
  const branch = `release/${channel}-${version}`;
  if ((await $`git ls-remote --exit-code --heads origin ${branch}`.quiet().nothrow()).exitCode === 0) {
    throw new Error(
      `origin already has a ${branch} branch. Finish or delete that pull request first.`,
    );
  }

  logStep(`Preparing ${branch}`);
  await $`git checkout --quiet -b ${branch} ${masterRef}`;
  try {
    const currentAppVersion = await versionAt(channel, "HEAD");
    const bump =
      channel === "desktop"
        ? await bumpDesktop(version)
        : plan.appVersion !== currentAppVersion
          ? await bumpIos(plan.appVersion)
          : { files: [] as string[] };
    const app = channel as NoteApp;
    const folded = await shipChangeNotes(projectRoot, app);
    const bullets = changelogBullets(folded, app);
    const path = join(projectRoot, changelogPath[channel]);
    const existing = await Bun.file(path).exists()
      ? await readFile(path, "utf8")
      : `# Shidou ${channel === "ios" ? "iOS" : ""} Changelog\n`;
    await writeFile(
      path,
      prependChangelogSection(
        existing,
        version,
        bullets.length > 0 ? bullets : ["- Maintenance release with no user-visible changes"],
      ),
    );

    await $`git add -A -- ${[...bump.files, changelogPath[channel], changesDirectoryName]}`;
    await $`git commit --quiet -m ${`chore(release): ${channel} ${version}`}`;
    await $`git push --quiet -u origin ${branch}`;

    logStep("Opening the release pull request");
    const labels = channel === "ios" ? [appLabel("ios"), noReleaseLabel] : [noReleaseLabel];
    const body =
      `Release ${channelNames[channel]} ${version}.\n\n` +
      (bullets.length > 0 ? `${bullets.join("\n")}\n\n` : "") +
      `Opened by \`bun run ship ${channel}\`; it merges once checks pass and then publishes.`;
    const url = (
      await $`gh pr create --base master --head ${branch} --title ${`chore(release): ${channel} ${version}`} --body ${body} --label ${labels.join(",")}`.text()
    ).trim();
    console.log(`  ${url}`);

    logStep("Waiting for checks");
    // Checks take a moment to register; `gh pr checks` errors until then.
    for (let attempt = 0; ; attempt++) {
      const result = await $`gh pr checks ${branch} --watch --fail-fast`.nothrow();
      if (result.exitCode === 0) break;
      const text = result.stderr.toString() + result.stdout.toString();
      if (/no checks reported/i.test(text) && attempt < 10) {
        await Bun.sleep(15_000);
        continue;
      }
      throw new Error(
        `Checks failed on ${url}. Fix master, close the pull request, and run ship again.`,
      );
    }

    logStep("Squash-merging");
    await $`gh pr merge ${branch} --squash --delete-branch --subject ${`chore(release): ${channel} ${version}`}`;
  } finally {
    await $`git checkout --quiet master`.nothrow();
    await $`git branch --quiet -D ${branch}`.quiet().nothrow();
  }

  await $`git fetch --quiet --tags origin`;
  await $`git pull --quiet --ff-only`;
  const merged = await git("rev-parse", "HEAD");
  const landed = await versionAt(channel, "HEAD");
  if (landed !== plan.appVersion) {
    throw new Error(
      `master is at ${landed} after the merge, not ${plan.appVersion}; something else landed. ` +
        "Run ship again to resume from the release commit.",
    );
  }
  return merged;
}

type RunSummary = { databaseId: number; headSha: string; status: string; conclusion: string; createdAt: string };

async function listRuns(workflow: string, extra: string[] = []): Promise<RunSummary[]> {
  return JSON.parse(
    await $`gh run list --workflow ${workflow} --limit 10 --json databaseId,headSha,status,conclusion,createdAt ${extra}`
      .quiet()
      .text(),
  ) as RunSummary[];
}

async function watchRun(id: number, what: string): Promise<void> {
  console.log(`  watching ${what} (run ${id})`);
  const result = await $`gh run watch ${String(id)} --exit-status --interval 30`.nothrow();
  if (result.exitCode !== 0) {
    throw new Error(`${what} failed (run ${id}). Inspect it with \`gh run view ${id}\`.`);
  }
}

/** A run of `workflow` on `sha` started after `since`, waiting briefly for
 *  GitHub to register it. */
async function awaitRun(
  workflow: string,
  since: Date,
  matches: (run: RunSummary) => boolean,
  timeoutMs = 3 * 60 * 1000,
): Promise<RunSummary | null> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const run = (await listRuns(workflow)).find(
      (candidate) => new Date(candidate.createdAt) >= since && matches(candidate),
    );
    if (run) return run;
    await Bun.sleep(10_000);
  }
  return null;
}

type Release = { isDraft: boolean; targetCommitish: string } | null;

async function releaseView(tag: string): Promise<Release> {
  const result = await $`gh release view ${tag} --json isDraft,targetCommitish`.quiet().nothrow();
  return result.exitCode === 0 ? (JSON.parse(result.stdout.toString()) as Release) : null;
}

/** Build on CI, publish the GitHub release (which creates the desktop/v tag
 *  at the built commit), and mirror the assets to R2. Each step is skipped
 *  when a previous run already did it. */
async function publishDesktop(version: string, sha: string): Promise<void> {
  const tag = `${tagPrefix.desktop}${version}`;
  let release = await releaseView(tag);

  if (release && !release.isDraft && !options.force) {
    console.log(`  ok   ${tag} is already published.`);
  } else {
    if (!release || options.force) {
      logStep(`Building Desktop ${version} on CI`);
      const since = new Date();
      await $`gh workflow run release.yml --ref master`;
      const run = await awaitRun("release.yml", since, (candidate) => candidate.headSha === sha);
      if (!run) {
        throw new Error(
          `The Release workflow did not start on ${sha.slice(0, 10)}; is master still at that commit?`,
        );
      }
      await watchRun(run.databaseId, "the Release workflow");
      release = await releaseView(tag);
      if (!release) throw new Error(`The Release workflow finished but left no ${tag} release.`);
    } else {
      console.log(`  ok   ${tag} is already built (draft release present).`);
    }
    if (release.isDraft) {
      logStep(`Publishing ${tag}`);
      await $`gh release edit ${tag} --draft=false --latest`;
    }
  }

  logStep("Mirroring the release to releases.shidou.dev");
  const since = new Date(Date.now() - 60 * 60 * 1000);
  let sync = await awaitRun(
    "sync-release.yml",
    since,
    (candidate) => candidate.status !== "completed" || candidate.conclusion === "success",
    2 * 60 * 1000,
  );
  if (!sync) {
    console.log("  no sync run found; dispatching one");
    const dispatched = new Date();
    await $`gh workflow run sync-release.yml -f ${`tag=${tag}`}`;
    sync = await awaitRun("sync-release.yml", dispatched, () => true);
    if (!sync) throw new Error("The Sync release workflow did not start.");
  }
  if (sync.status !== "completed") await watchRun(sync.databaseId, "the Sync release workflow");
  else console.log(`  ok   sync already succeeded (run ${sync.databaseId})`);

  await $`git fetch --quiet --tags origin`;
  const tagged = await git("rev-list", "-n", "1", tag);
  if (tagged !== sha) {
    console.warn(
      `\nWarning: ${tag} points at ${tagged.slice(0, 10)}, not the merge commit ${sha.slice(0, 10)}.`,
    );
  }
  console.log(`\nDesktop ${version} is live. Delivery Record: ${tag}.`);
}

/** Archive, upload, and wait for TestFlight; then record the marketing
 *  version and build number at the delivered commit. */
async function publishIos(plan: ReleasePlan, sha: string): Promise<void> {
  const { appVersion, buildNumber, version } = plan;
  if (!buildNumber) throw new Error("The iOS release plan has no build number.");
  const tag = `${tagPrefix.ios}${version}`;
  if ((await tagExists(tag)) && !options.force) {
    console.log(`  ok   ${tag} already exists.`);
    return;
  }
  logStep("Running the ShidouKit tests");
  await $`swift test --package-path ${join(projectRoot, "apps/ios/Packages/ShidouKit")}`;

  logStep(`Uploading iOS ${appVersion} (build ${buildNumber}) to TestFlight`);
  await $`bun run ios-release --upload --build-number ${buildNumber} --wait`;

  logStep(`Recording the delivery as ${tag}`);
  if (await tagExists(tag)) {
    console.log(`  ok   ${tag} kept at ${(await git("rev-list", "-n", "1", tag)).slice(0, 10)}`);
  } else {
    await $`git tag -a ${tag} ${sha} -m ${`iOS ${appVersion} build ${buildNumber}`}`;
    await $`git push --quiet origin ${`refs/tags/${tag}`}`;
  }
  console.log(
    `\niOS ${appVersion} (build ${buildNumber}) is in TestFlight. Delivery Record: ${tag}.`,
  );
}

async function shipRelease(channel: "desktop" | "ios", status: ChannelStatus): Promise<void> {
  const master = await requireCleanMaster();
  await checkProtocol(channel, master);
  const plan = await planRelease(channel, status, master);
  printPlan(plan, status);
  if (options.dryRun) {
    console.log("\nDry run; nothing changed.");
    return;
  }
  const sha = plan.resume ? master : await landReleasePullRequest(plan);
  if (channel === "desktop") await publishDesktop(plan.version, sha);
  else await publishIos(plan, sha);
}

async function shipWorker(channel: "browser" | "website", status: ChannelStatus): Promise<void> {
  console.log(describeStatus(status).join("\n"));
  if (!options.force) {
    console.log(
      `\n${channelNames[channel]} deploys automatically when a pull request merges to master` +
        (isAffected(status)
          ? "; the changes above will ship with the next merge, or pass --force to redeploy master now."
          : "; nothing is waiting. Pass --force to redeploy master anyway."),
    );
    return;
  }
  if (channel === "browser") await checkProtocol(channel, await git("rev-parse", masterRef));
  if (options.dryRun) {
    console.log("\nDry run; would dispatch deploy-workers.yml.");
    return;
  }
  logStep(`Deploying ${channelNames[channel]} from master`);
  const since = new Date();
  const worker = channel === "browser" ? "web" : "website";
  await $`gh workflow run deploy-workers.yml --ref master -f ${`worker=${worker}`} -f ${`force_protocol=${options.forceProtocol}`}`;
  const run = await awaitRun("deploy-workers.yml", since, () => true);
  if (!run) throw new Error("The deploy-workers workflow did not start.");
  await watchRun(run.databaseId, `the ${channelNames[channel]}`);
  console.log(`\n${channelNames[channel]} redeployed from master.`);
}

async function ship(channel: Channel, statuses: ChannelStatus[]): Promise<void> {
  const status = statuses.find((candidate) => candidate.channel === channel)!;
  if (channel === "desktop" || channel === "ios") await shipRelease(channel, status);
  else await shipWorker(channel, status);
}

await preflight();
const requested = positionals[0];

if (requested === "status") {
  printStatuses(await allStatuses());
  process.exit(0);
}
if (requested !== undefined && !isChannel(requested)) {
  throw new Error(`Unknown channel "${requested}". Channels: ${channels.join(", ")}.`);
}

const statuses = await allStatuses();
if (requested) {
  await ship(requested, statuses);
  process.exit(0);
}

const affected = statuses.filter(isAffected);
if (affected.length === 0) {
  printStatuses(statuses);
  console.log("Nothing to ship: every channel is at master.");
  process.exit(0);
}
if (affected.length === 1) {
  console.log(`One channel changed since it last shipped: ${channelNames[affected[0]!.channel]}.\n`);
  await ship(affected[0]!.channel, statuses);
  process.exit(0);
}

printStatuses(affected);
const names = affected.map((status) => status.channel);
if (process.env.CI) {
  console.error(
    `Several channels changed (${names.join(", ")}). Pass the channel explicitly: bun run ship <channel>.`,
  );
  process.exit(1);
}
process.stdout.write(`Which channel? [${names.join("/")}] `);
const answer = (await new Promise<string>((resolveAnswer) => {
  process.stdin.setEncoding("utf8");
  process.stdin.once("data", (chunk) => resolveAnswer(String(chunk)));
})).trim();
process.stdin.pause();
if (!isChannel(answer) || !names.includes(answer)) {
  throw new Error(`Not one of ${names.join(", ")}; nothing shipped.`);
}
await ship(answer, statuses);

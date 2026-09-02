/** Delivery Channels and their Delivery Records: what each channel last
 *  shipped, and what `master` holds beyond it. Desktop and iOS record a
 *  delivery with a `desktop/v*` or `ios/v*` tag pushed only after users can
 *  receive the build; Browser and website record one as a successful GitHub
 *  deployment written by deploy-workers.yml. See RELEASING.md. */

import { $ } from "bun";
import { type ChangeNote, type NoteApp, readChangeNotes } from "./changes";
import { type App, apps, sharedPaths, strictPaths } from "./pr-check";

export type Channel = App;
export const channels = apps;

export const channelNames: Record<Channel, string> = {
  desktop: "Desktop Release",
  ios: "iOS Release",
  browser: "Browser Deployment",
  website: "Website Deployment",
};

export const tagPrefix: Partial<Record<Channel, string>> = {
  desktop: "desktop/v",
  ios: "ios/v",
};

/** GitHub deployment environment names written by deploy-workers.yml. */
export const deploymentEnvironment: Partial<Record<Channel, string>> = {
  browser: "browser",
  website: "website",
};

export type DeliveryRecord = {
  /** Human label: the tag, or `deployment #<id>`. */
  label: string;
  sha: string;
  version?: string;
};

export type ChannelStatus = {
  channel: Channel;
  record: DeliveryRecord | null;
  /** Files changed on `master` since the record that this channel ships. */
  files: string[];
  /** Change Notes still owed to this channel. */
  notes: ChangeNote[];
};

const versionOrder = new Intl.Collator("en", { numeric: true });

/** The newest `<prefix><version>` tag by version order, not by date. */
export function latestVersionTag(
  tags: string[],
  prefix: string,
): { tag: string; version: string } | null {
  const candidates = tags
    .filter((tag) => tag.startsWith(prefix))
    .map((tag) => ({ tag, version: tag.slice(prefix.length) }))
    .filter(({ version }) => /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version))
    .sort((a, b) => versionOrder.compare(b.version, a.version));
  return candidates[0] ?? null;
}

/** Paths whose changes this channel ships: its own strict paths plus, for
 *  the Clients, the shared daemon, protocol, and client-library code. */
export function channelPaths(channel: Channel): string[] {
  return channel === "website"
    ? strictPaths.website
    : [...strictPaths[channel], ...sharedPaths];
}

export function filesForChannel(files: string[], channel: Channel): string[] {
  const prefixes = channelPaths(channel);
  return files.filter((file) => prefixes.some((prefix) => file.startsWith(prefix)));
}

export function isAffected(status: ChannelStatus): boolean {
  return status.record === null || status.files.length > 0 || status.notes.length > 0;
}

async function tagRecord(prefix: string): Promise<DeliveryRecord | null> {
  const tags = (await $`git tag --list ${`${prefix}*`}`.quiet().text())
    .split("\n")
    .filter(Boolean);
  const latest = latestVersionTag(tags, prefix);
  if (!latest) return null;
  const sha = (await $`git rev-list -n 1 ${latest.tag}`.quiet().text()).trim();
  return { label: latest.tag, sha, version: latest.version };
}

type Deployment = { id: number; sha: string; environment: string };

async function deploymentRecord(environment: string): Promise<DeliveryRecord | null> {
  // Newest first; the first one whose latest status is `success` is the
  // record. Failed and in-progress deployments do not count as shipped.
  const deployments = JSON.parse(
    await $`gh api ${`repos/{owner}/{repo}/deployments?environment=${environment}&per_page=20`}`
      .quiet()
      .text(),
  ) as Deployment[];
  for (const deployment of deployments) {
    const statuses = JSON.parse(
      await $`gh api ${`repos/{owner}/{repo}/deployments/${deployment.id}/statuses?per_page=1`}`
        .quiet()
        .text(),
    ) as Array<{ state: string }>;
    if (statuses[0]?.state === "success") {
      return { label: `deployment #${deployment.id}`, sha: deployment.sha };
    }
  }
  return null;
}

export async function deliveryRecord(channel: Channel): Promise<DeliveryRecord | null> {
  const prefix = tagPrefix[channel];
  if (prefix) return tagRecord(prefix);
  return deploymentRecord(deploymentEnvironment[channel]!);
}

/** Status of one channel against `ref` (normally `origin/master`). */
export async function channelStatus(
  projectRoot: string,
  channel: Channel,
  ref: string,
  allNotes?: ChangeNote[],
): Promise<ChannelStatus> {
  const record = await deliveryRecord(channel);
  let files: string[] = [];
  if (record) {
    const reachable =
      (await $`git merge-base --is-ancestor ${record.sha} ${ref}`.quiet().nothrow()).exitCode ===
      0;
    files = reachable
      ? filesForChannel(
          (await $`git diff --name-only ${record.sha} ${ref}`.quiet().text())
            .split("\n")
            .filter(Boolean),
          channel,
        )
      : // A record that is not on master (a hotfix branch, a rewritten
        // history) cannot be diffed meaningfully; treat everything as new.
        [`(${record.label} is not an ancestor of ${ref})`];
  }
  const notes = allNotes ?? (await readChangeNotes(projectRoot));
  const pending =
    channel === "website"
      ? []
      : notes.filter(
          (note) =>
            note.wording[channel as NoteApp] && !note.shipped.includes(channel as NoteApp),
        );
  return { channel, record, files, notes: pending };
}

export function describeStatus(status: ChannelStatus): string[] {
  const lines = [`${channelNames[status.channel]}:`];
  lines.push(
    status.record
      ? `  last shipped  ${status.record.label} (${status.record.sha.slice(0, 10)})`
      : "  last shipped  never (no delivery record yet)",
  );
  if (status.files.length > 0) {
    const shown = status.files.slice(0, 5);
    lines.push(
      `  code changed  ${status.files.length} file${status.files.length === 1 ? "" : "s"}: ` +
        shown.join(", ") +
        (status.files.length > shown.length ? ", …" : ""),
    );
  } else if (status.record) {
    lines.push("  code changed  none");
  }
  if (status.channel !== "website") {
    lines.push(
      status.notes.length > 0
        ? `  pending notes ${status.notes.length}:`
        : "  pending notes none",
    );
    for (const note of status.notes) {
      lines.push(`    - ${note.wording[status.channel as NoteApp]}  (.changes/${note.slug}.md)`);
    }
  }
  return lines;
}

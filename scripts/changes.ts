/** Change Notes: one Markdown file per user-visible change under `.changes/`,
 *  carrying release-note wording for every Client the change reaches. The
 *  pull request that lands the change adds the file; each Delivery Channel's
 *  release folds the wording into its own changelog and marks the note
 *  shipped for that channel; the file is deleted once every channel it names
 *  has shipped it. See RELEASING.md and docs/adr/0004-independent-delivery-channels.md.
 *
 *  File shape:
 *
 *      ---
 *      desktop: Choose Claude Fable 5.1 from the model picker
 *      ios: same-as desktop
 *      browser: Pick Claude Fable 5.1 in the model menu
 *      shipped: [desktop]
 *      ---
 *      Optional longer detail, never published.
 *
 *  The pure helpers here are the whole format; `changes.ts` is also runnable
 *  (`bun scripts/changes.ts <command>`) for CI and the release scripts. */

import { readdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";

/** The Clients a note can carry wording for. `app:website` PRs never carry
 *  notes, so the website is not a note app. */
export const noteApps = ["desktop", "ios", "browser"] as const;
export type NoteApp = (typeof noteApps)[number];

export const changesDirectoryName = ".changes";

export type ChangeNote = {
  /** File name without the `.md` extension. */
  slug: string;
  /** Resolved wording per app; `same-as` references are already followed. */
  wording: Partial<Record<NoteApp, string>>;
  /** Apps whose Delivery Channel has already shipped this note. */
  shipped: NoteApp[];
  /** Everything after the frontmatter, trimmed. */
  body: string;
};

export class ChangeNoteError extends Error {}

function isNoteApp(value: string): value is NoteApp {
  return (noteApps as readonly string[]).includes(value);
}

function splitFrontmatter(source: string): { frontmatter: string; body: string } {
  const lines = source.split("\n");
  if (lines[0]?.trim() !== "---") {
    throw new ChangeNoteError("must start with a `---` frontmatter line");
  }
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === "---");
  if (end === -1) {
    throw new ChangeNoteError("frontmatter is not closed by a second `---` line");
  }
  return {
    frontmatter: lines.slice(1, end).join("\n"),
    body: lines.slice(end + 1).join("\n").trim(),
  };
}

/** Parse one note. Throws `ChangeNoteError` with a message that names what is
 *  wrong; callers prefix the file name. */
export function parseChangeNote(slug: string, source: string): ChangeNote {
  const { frontmatter, body } = splitFrontmatter(source);
  let data: unknown;
  try {
    data = Bun.YAML.parse(frontmatter);
  } catch (error) {
    throw new ChangeNoteError(
      `frontmatter is not valid YAML: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new ChangeNoteError("frontmatter must be a YAML mapping");
  }
  const record = data as Record<string, unknown>;

  const raw: Partial<Record<NoteApp, string>> = {};
  const aliases: Partial<Record<NoteApp, NoteApp>> = {};
  for (const [key, value] of Object.entries(record)) {
    if (key === "shipped") continue;
    if (!isNoteApp(key)) {
      throw new ChangeNoteError(
        `unknown key \`${key}\`; use ${noteApps.join(", ")}, or shipped`,
      );
    }
    if (typeof value !== "string" || !value.trim()) {
      throw new ChangeNoteError(`\`${key}\` must be a non-empty string`);
    }
    const alias = value.trim().match(/^same-as\s+(\S+)$/);
    if (alias) {
      const target = alias[1]!;
      if (!isNoteApp(target)) {
        throw new ChangeNoteError(`\`${key}\` refers to unknown app \`${target}\``);
      }
      if (target === key) {
        throw new ChangeNoteError(`\`${key}\` cannot be same-as itself`);
      }
      aliases[key] = target;
    } else {
      raw[key] = value.trim();
    }
  }

  const wording: Partial<Record<NoteApp, string>> = { ...raw };
  for (const [app, target] of Object.entries(aliases) as [NoteApp, NoteApp][]) {
    const text = raw[target];
    if (!text) {
      throw new ChangeNoteError(
        `\`${app}\` is same-as \`${target}\`, but \`${target}\` has no wording of its own`,
      );
    }
    wording[app] = text;
  }
  if (Object.keys(wording).length === 0) {
    throw new ChangeNoteError(`has no wording for any app (${noteApps.join(", ")})`);
  }

  const shippedValue = record.shipped ?? [];
  if (!Array.isArray(shippedValue)) {
    throw new ChangeNoteError("`shipped` must be a list");
  }
  const shipped: NoteApp[] = [];
  for (const entry of shippedValue) {
    if (typeof entry !== "string" || !isNoteApp(entry)) {
      throw new ChangeNoteError(`\`shipped\` contains unknown app \`${String(entry)}\``);
    }
    if (!wording[entry]) {
      throw new ChangeNoteError(
        `\`shipped\` names \`${entry}\`, which has no wording in this note`,
      );
    }
    if (!shipped.includes(entry)) shipped.push(entry);
  }

  return { slug, wording, shipped, body };
}

/** Serialize a note back to its file form. Aliases are not preserved: every
 *  app gets its resolved wording, which keeps the file readable on its own. */
export function formatChangeNote(note: ChangeNote): string {
  const lines = ["---"];
  for (const app of noteApps) {
    const text = note.wording[app];
    if (text) lines.push(`${app}: ${yamlScalar(text)}`);
  }
  if (note.shipped.length > 0) {
    lines.push(`shipped: [${note.shipped.join(", ")}]`);
  }
  lines.push("---");
  const body = note.body.trim();
  return body ? `${lines.join("\n")}\n${body}\n` : `${lines.join("\n")}\n`;
}

/** Quote a scalar only when YAML would otherwise misread it. */
function yamlScalar(text: string): string {
  const needsQuotes =
    /^[\s"'#&*!|>%@`[\]{},?-]/.test(text) ||
    /[:#]\s/.test(text) ||
    /:$/.test(text) ||
    /^same-as\s/.test(text) ||
    /^(true|false|null|yes|no|~)$/i.test(text) ||
    /^[\d.+-]+$/.test(text) ||
    text.includes("\n");
  return needsQuotes ? JSON.stringify(text) : text;
}

/** Apps this note still owes a release to. */
export function pendingApps(note: ChangeNote): NoteApp[] {
  return noteApps.filter((app) => note.wording[app] && !note.shipped.includes(app));
}

export function isFullyShipped(note: ChangeNote): boolean {
  return pendingApps(note).length === 0;
}

/** Mark `app` shipped. Returns null when every app has now shipped, meaning
 *  the caller should delete the file rather than rewrite it. */
export function markShipped(note: ChangeNote, app: NoteApp): ChangeNote | null {
  if (!note.wording[app]) {
    throw new ChangeNoteError(`has no wording for ${app}, so it cannot ship there`);
  }
  const shipped = note.shipped.includes(app) ? note.shipped : [...note.shipped, app];
  const updated = { ...note, shipped };
  return isFullyShipped(updated) ? null : updated;
}

/** Render the wording of `notes` for `app` as Keep-a-Changelog bullets. */
export function changelogBullets(notes: ChangeNote[], app: NoteApp): string[] {
  return notes.flatMap((note) => {
    const text = note.wording[app];
    return text ? [`- ${text.replace(/\n+/g, " ").trim()}`] : [];
  });
}

/** Insert a `## [version]` section at the top of a Keep-a-Changelog file,
 *  after the intro paragraph and before the first existing section. A file
 *  with no sections gets the section appended. Refuses to duplicate a
 *  version that already has a section. */
export function prependChangelogSection(
  changelog: string,
  version: string,
  bullets: string[],
): string {
  const heading = `## [${version}]`;
  const lines = changelog.split("\n");
  if (lines.some((line) => line.trim() === heading || line.startsWith(`${heading} `))) {
    throw new ChangeNoteError(`changelog already has a ${heading} section`);
  }
  const section = [heading, "", ...bullets, ""];
  const first = lines.findIndex((line) => /^##\s+/.test(line));
  if (first === -1) {
    const trimmed = changelog.replace(/\s+$/, "");
    return `${trimmed ? `${trimmed}\n\n` : ""}${section.join("\n")}`.replace(/\n*$/, "\n");
  }
  return [...lines.slice(0, first), ...section, ...lines.slice(first)].join("\n");
}

/** Read every note under `.changes/`. Invalid notes are reported together so
 *  one CI run shows every problem. */
export async function readChangeNotes(projectRoot: string): Promise<ChangeNote[]> {
  const directory = join(projectRoot, changesDirectoryName);
  let entries: string[];
  try {
    entries = await readdir(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
  const notes: ChangeNote[] = [];
  const problems: string[] = [];
  for (const entry of entries.sort()) {
    if (!entry.endsWith(".md") || entry.startsWith(".") || entry === "README.md") continue;
    const slug = basename(entry, ".md");
    const source = await readFile(join(directory, entry), "utf8");
    try {
      notes.push(parseChangeNote(slug, source));
    } catch (error) {
      problems.push(
        `${changesDirectoryName}/${entry}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
  if (problems.length > 0) {
    throw new ChangeNoteError(problems.join("\n"));
  }
  return notes;
}

/** Rewrite or delete every note after marking `app` shipped. Returns the
 *  notes that were folded into this release. */
export async function shipChangeNotes(
  projectRoot: string,
  app: NoteApp,
): Promise<ChangeNote[]> {
  const notes = await readChangeNotes(projectRoot);
  const folded: ChangeNote[] = [];
  for (const note of notes) {
    if (!note.wording[app] || note.shipped.includes(app)) continue;
    folded.push(note);
    const path = join(projectRoot, changesDirectoryName, `${note.slug}.md`);
    const updated = markShipped(note, app);
    if (updated) {
      await writeFile(path, formatChangeNote(updated));
    } else {
      await rm(path);
    }
  }
  return folded;
}

/** A slug from a PR title or free text: lowercase words joined by dashes. */
export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60)
    .replace(/-+$/, "");
}

if (import.meta.main) {
  const projectRoot = resolve(import.meta.dir, "..");
  const [command, ...rest] = Bun.argv.slice(2);
  switch (command) {
    case "check": {
      // Validate every note; used by CI and as a pre-commit sanity check.
      const notes = await readChangeNotes(projectRoot);
      console.log(`${notes.length} change note${notes.length === 1 ? "" : "s"} valid.`);
      break;
    }
    case "pending": {
      // List notes still owed to an app, one wording per line.
      const app = rest[0];
      if (!app || !isNoteApp(app)) {
        throw new Error(`Usage: bun scripts/changes.ts pending <${noteApps.join("|")}>`);
      }
      const notes = (await readChangeNotes(projectRoot)).filter(
        (note) => note.wording[app] && !note.shipped.includes(app),
      );
      for (const line of changelogBullets(notes, app)) console.log(line);
      break;
    }
    case "ship": {
      // Mark an app shipped across every pending note, rewriting or deleting
      // files. The release scripts call this after folding the wording into
      // the channel's changelog.
      const app = rest[0];
      if (!app || !isNoteApp(app)) {
        throw new Error(`Usage: bun scripts/changes.ts ship <${noteApps.join("|")}>`);
      }
      const folded = await shipChangeNotes(projectRoot, app);
      console.log(`Marked ${folded.length} note${folded.length === 1 ? "" : "s"} shipped for ${app}.`);
      break;
    }
    default:
      console.log(
        "Usage: bun scripts/changes.ts <check | pending <app> | ship <app>>\n" +
          `Apps: ${noteApps.join(", ")}`,
      );
      process.exit(command ? 1 : 0);
  }
}

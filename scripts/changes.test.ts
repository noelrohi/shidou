import { describe, expect, test } from "bun:test";
import { mkdtemp, readdir, readFile, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  changelogBullets,
  formatChangeNote,
  markShipped,
  parseChangeNote,
  pendingApps,
  prependChangelogSection,
  readChangeNotes,
  shipChangeNotes,
  slugify,
} from "./changes";

const note = (frontmatter: string, body = "") =>
  `---\n${frontmatter}\n---\n${body}`;

describe("parseChangeNote", () => {
  test("reads wording per app and an empty shipped list", () => {
    const parsed = parseChangeNote(
      "model-picker",
      note("desktop: Pick Fable 5.1 from the model picker\nbrowser: Pick Fable 5.1"),
    );
    expect(parsed.wording).toEqual({
      desktop: "Pick Fable 5.1 from the model picker",
      browser: "Pick Fable 5.1",
    });
    expect(parsed.shipped).toEqual([]);
    expect(parsed.body).toBe("");
  });

  test("follows same-as references", () => {
    const parsed = parseChangeNote(
      "x",
      note("desktop: Archive tasks\nios: same-as desktop\nbrowser: same-as desktop"),
    );
    expect(parsed.wording.ios).toBe("Archive tasks");
    expect(parsed.wording.browser).toBe("Archive tasks");
  });

  test("keeps the body", () => {
    const parsed = parseChangeNote("x", note("desktop: A", "Longer detail.\n"));
    expect(parsed.body).toBe("Longer detail.");
  });

  test("reads shipped apps", () => {
    const parsed = parseChangeNote("x", note("desktop: A\nios: B\nshipped: [desktop]"));
    expect(parsed.shipped).toEqual(["desktop"]);
    expect(pendingApps(parsed)).toEqual(["ios"]);
  });

  test.each([
    ["no frontmatter", "desktop: A", /must start with/],
    ["unclosed frontmatter", "---\ndesktop: A\n", /not closed/],
    ["unknown key", note("mac: A"), /unknown key `mac`/],
    ["empty wording", note("desktop: ''"), /non-empty/],
    ["no apps", note("shipped: []"), /no wording for any app/],
    ["same-as unknown", note("desktop: same-as web"), /unknown app `web`/],
    ["same-as self", note("desktop: same-as desktop"), /same-as itself/],
    ["same-as missing", note("ios: same-as desktop"), /has no wording of its own/],
    ["shipped unknown", note("desktop: A\nshipped: [web]"), /unknown app `web`/],
    ["shipped without wording", note("desktop: A\nshipped: [ios]"), /has no wording in this note/],
    ["shipped not a list", note("desktop: A\nshipped: desktop"), /must be a list/],
  ])("rejects %s", (_name, source, message) => {
    expect(() => parseChangeNote("x", source)).toThrow(message);
  });
});

describe("formatChangeNote", () => {
  test("round-trips with resolved wording and shipped apps", () => {
    const parsed = parseChangeNote(
      "x",
      note("desktop: A\nios: same-as desktop\nshipped: [ios]", "Body."),
    );
    const text = formatChangeNote(parsed);
    expect(text).toBe("---\ndesktop: A\nios: A\nshipped: [ios]\n---\nBody.\n");
    expect(parseChangeNote("x", text)).toEqual(parsed);
  });

  test("quotes wording YAML would misread", () => {
    const parsed = parseChangeNote("x", note('desktop: "Settings: General now remembers"'));
    const text = formatChangeNote(parsed);
    expect(text).toContain('desktop: "Settings: General now remembers"');
    expect(parseChangeNote("x", text).wording.desktop).toBe("Settings: General now remembers");
  });
});

describe("markShipped", () => {
  test("adds the app and keeps the note while others are pending", () => {
    const parsed = parseChangeNote("x", note("desktop: A\nios: B"));
    expect(markShipped(parsed, "desktop")?.shipped).toEqual(["desktop"]);
  });

  test("returns null once every app has shipped", () => {
    const parsed = parseChangeNote("x", note("desktop: A\nios: B\nshipped: [ios]"));
    expect(markShipped(parsed, "desktop")).toBeNull();
  });

  test("refuses an app the note has no wording for", () => {
    const parsed = parseChangeNote("x", note("desktop: A"));
    expect(() => markShipped(parsed, "ios")).toThrow(/cannot ship there/);
  });
});

describe("changelogBullets", () => {
  test("renders one bullet per note that names the app", () => {
    const notes = [
      parseChangeNote("a", note("desktop: First\nios: Phone first")),
      parseChangeNote("b", note("ios: Phone only")),
      parseChangeNote("c", note("desktop: Third")),
    ];
    expect(changelogBullets(notes, "desktop")).toEqual(["- First", "- Third"]);
    expect(changelogBullets(notes, "ios")).toEqual(["- Phone first", "- Phone only"]);
  });
});

describe("prependChangelogSection", () => {
  const changelog = "# Changelog\n\nIntro.\n\n## [0.2.14]\n\n- Old\n";

  test("inserts before the first section", () => {
    expect(prependChangelogSection(changelog, "0.2.15", ["- New"])).toBe(
      "# Changelog\n\nIntro.\n\n## [0.2.15]\n\n- New\n\n## [0.2.14]\n\n- Old\n",
    );
  });

  test("appends to a changelog with no sections yet", () => {
    expect(prependChangelogSection("# iOS Changelog\n\nIntro.\n", "0.3.0", ["- New"])).toBe(
      "# iOS Changelog\n\nIntro.\n\n## [0.3.0]\n\n- New\n",
    );
  });

  test("refuses a duplicate version", () => {
    expect(() => prependChangelogSection(changelog, "0.2.14", ["- Dup"])).toThrow(
      /already has/,
    );
  });
});

describe("readChangeNotes / shipChangeNotes", () => {
  async function fixture(files: Record<string, string>): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), "shidou-changes-"));
    await mkdir(join(root, ".changes"));
    for (const [name, source] of Object.entries(files)) {
      await writeFile(join(root, ".changes", name), source);
    }
    return root;
  }

  test("returns nothing when the directory is missing", async () => {
    const root = await mkdtemp(join(tmpdir(), "shidou-changes-"));
    expect(await readChangeNotes(root)).toEqual([]);
  });

  test("reports every invalid note at once", async () => {
    const root = await fixture({
      "bad-one.md": "no frontmatter",
      "bad-two.md": note("web: A"),
      "good.md": note("desktop: A"),
    });
    await expect(readChangeNotes(root)).rejects.toThrow(
      /bad-one\.md: must start with[\s\S]*bad-two\.md: unknown key/,
    );
  });

  test("ships an app across notes, deleting fully shipped ones", async () => {
    const root = await fixture({
      "both.md": note("desktop: A\nios: B"),
      "desktop-only.md": note("desktop: C"),
      "ios-only.md": note("ios: D"),
      "already.md": note("desktop: E\nshipped: [desktop]"),
    });
    const folded = await shipChangeNotes(root, "desktop");
    expect(folded.map((n) => n.slug)).toEqual(["both", "desktop-only"]);
    expect((await readdir(join(root, ".changes"))).sort()).toEqual([
      "already.md",
      "both.md",
      "ios-only.md",
    ]);
    expect(await readFile(join(root, ".changes", "both.md"), "utf8")).toContain(
      "shipped: [desktop]",
    );
  });
});

describe("slugify", () => {
  test("makes a file-safe slug from a title", () => {
    expect(slugify("feat(claude): add Fable 5.1 & Mythos 5 models!")).toBe(
      "feat-claude-add-fable-5-1-mythos-5-models",
    );
  });
});

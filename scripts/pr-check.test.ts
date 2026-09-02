import { describe, expect, test } from "bun:test";
import { parseChangeNote } from "./changes";
import {
  appsFromPaths,
  evaluatePullRequest,
  protocolVersionChangedIn,
} from "./pr-check";

const note = (frontmatter: string, added = true) => ({
  note: parseChangeNote("n", `---\n${frontmatter}\n---\n`),
  added,
});

const facts = (overrides: Partial<Parameters<typeof evaluatePullRequest>[0]>) =>
  evaluatePullRequest({
    labels: [],
    changedFiles: [],
    protocolVersionChanged: false,
    notes: [],
    ...overrides,
  });

describe("appsFromPaths", () => {
  test("maps strict paths to their app", () => {
    expect(
      appsFromPaths(["apps/ios/Shidou/App.swift", "website/src/index.tsx", "src/app.rs"]),
    ).toEqual(["desktop", "ios", "website"]);
  });

  test("ignores shared and unrelated paths", () => {
    expect(appsFromPaths(["crates/shidou-core/src/lib.rs", "README.md", "bun.lock"])).toEqual(
      [],
    );
  });
});

describe("evaluatePullRequest", () => {
  test("requires an app label or no-release", () => {
    const { errors } = facts({ changedFiles: ["README.md"] });
    expect(errors).toHaveLength(1);
    expect(errors[0]).toMatch(/Label the pull request/);
  });

  test("accepts no-release for a docs change", () => {
    expect(facts({ labels: ["no-release"], changedFiles: ["README.md"] })).toEqual({
      errors: [],
      warnings: [],
    });
  });

  test("fails when a strict path changed without its label", () => {
    const { errors } = facts({
      labels: ["app:desktop", "no-release"],
      changedFiles: ["src/app.rs", "apps/ios/Shidou/App.swift"],
    });
    expect(errors).toEqual([
      expect.stringMatching(/apps\/ios\/Shidou\/App.swift.*needs the `app:ios` label/),
    ]);
  });

  test("allows extra labels beyond what the paths show", () => {
    const { errors } = facts({
      labels: ["app:desktop", "app:browser"],
      changedFiles: ["src/app.rs"],
      notes: [note("desktop: A\nbrowser: B")],
    });
    expect(errors).toEqual([]);
  });

  test("only warns for shared code without every client label", () => {
    const { errors, warnings } = facts({
      labels: ["app:desktop"],
      changedFiles: ["crates/shidou-core/src/server.rs"],
      notes: [note("desktop: A")],
    });
    expect(errors).toEqual([]);
    expect(warnings).toEqual([expect.stringMatching(/shared code.*ios, browser/)]);
  });

  test("blocks a protocol version change without every client and protocol:breaking", () => {
    const { errors } = facts({
      labels: ["app:desktop", "app:ios"],
      changedFiles: ["crates/shidou-protocol/src/protocol.rs"],
      protocolVersionChanged: true,
      notes: [note("desktop: A\nios: B")],
    });
    expect(errors).toEqual([
      expect.stringMatching(/PROTOCOL_VERSION changed.*`app:browser`, `protocol:breaking`/),
    ]);
  });

  test("passes a protocol version change with the full label set", () => {
    const { errors } = facts({
      labels: ["app:desktop", "app:ios", "app:browser", "protocol:breaking"],
      changedFiles: ["crates/shidou-protocol/src/protocol.rs"],
      protocolVersionChanged: true,
      notes: [note("desktop: A\nios: same-as desktop\nbrowser: same-as desktop")],
    });
    expect(errors).toEqual([]);
  });

  test("warns about a stale protocol:breaking label", () => {
    const { warnings } = facts({
      labels: ["no-release", "protocol:breaking"],
      changedFiles: ["README.md"],
    });
    expect(warnings).toEqual([expect.stringMatching(/did not change/)]);
  });

  test("requires wording for every labeled client", () => {
    const { errors } = facts({
      labels: ["app:desktop", "app:ios", "app:website"],
      changedFiles: ["src/app.rs", "apps/ios/A.swift", "website/a.ts"],
      notes: [note("desktop: A")],
    });
    expect(errors).toEqual([expect.stringMatching(/`app:ios` is set, but no Change Note/)]);
  });

  test("website needs no note", () => {
    expect(facts({ labels: ["app:website"], changedFiles: ["website/a.ts"] }).errors).toEqual(
      [],
    );
  });

  test("rejects wording for an app the PR is not labeled with", () => {
    const { errors } = facts({
      labels: ["app:desktop"],
      changedFiles: ["src/app.rs"],
      notes: [note("desktop: A\nbrowser: B")],
    });
    expect(errors).toEqual([expect.stringMatching(/`browser:` wording.*not labeled `app:browser`/)]);
  });

  test("rejects a note alongside no-release", () => {
    const { errors } = facts({
      labels: ["app:desktop", "no-release"],
      changedFiles: ["src/app.rs"],
      notes: [note("desktop: A")],
    });
    expect(errors).toEqual([expect.stringMatching(/Drop the label or the note/)]);
  });

  test("lets a release PR mark existing notes shipped under no-release", () => {
    const { errors } = facts({
      labels: ["app:ios", "no-release"],
      changedFiles: ["apps/ios/project.yml", ".changes/n.md", "CHANGELOG-ios.md"],
      notes: [note("desktop: A\nios: B\nshipped: [ios]", false)],
    });
    expect(errors).toEqual([]);
  });

  test("accepts app labels with no-release for a refactor", () => {
    expect(facts({ labels: ["app:desktop", "no-release"], changedFiles: ["src/app.rs"] })).toEqual(
      { errors: [], warnings: [] },
    );
  });
});

describe("protocolVersionChangedIn", () => {
  test("detects a changed constant line", () => {
    expect(
      protocolVersionChangedIn(
        "-pub const PROTOCOL_VERSION: u32 = 6;\n+pub const PROTOCOL_VERSION: u32 = 7;\n",
      ),
    ).toBe(true);
  });

  test("ignores other edits to the file", () => {
    expect(protocolVersionChangedIn("+/// A comment about PROTOCOL_VERSION\n")).toBe(false);
  });
});

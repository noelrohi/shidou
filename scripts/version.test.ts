import { describe, expect, test } from "bun:test";
import {
  findIosVersion,
  nextVersion,
  setIosVersion,
  derivedBuildNumber,
  findPackageVersion,
  parseVersion,
} from "./version";

describe("findPackageVersion", () => {
  test("reads the version of the root [package] table", () => {
    const manifest = [
      "[package]",
      'name = "shidou"',
      'version = "0.2.9"',
      "",
      "[dependencies]",
      'serde = "1"',
    ].join("\n");
    expect(findPackageVersion(manifest)).toEqual({ line: 2, version: "0.2.9" });
  });

  test("ignores version keys in later tables", () => {
    const manifest = [
      "[package]",
      'name = "shidou"',
      'version = "0.2.9"',
      "",
      "[package.metadata.notes]",
      'version = "not-the-release"',
    ].join("\n");
    expect(findPackageVersion(manifest).version).toBe("0.2.9");
  });

  test("reports the line the version sits on", () => {
    const manifest = "\n[package]\nversion = \"1.0.0\"\n";
    expect(findPackageVersion(manifest)).toEqual({ line: 2, version: "1.0.0" });
  });

  test("throws when the root table has no version", () => {
    const manifest = "[package]\nname = \"shidou\"\n\n[dependencies]\n";
    expect(() => findPackageVersion(manifest)).toThrow(/version/);
  });

  test("throws when there is no [package] table at all", () => {
    expect(() => findPackageVersion("[dependencies]\n")).toThrow(/version/);
  });
});

describe("parseVersion", () => {
  test("parses a plain triple", () => {
    expect(parseVersion("0.2.9")).toEqual([0, 2, 9]);
  });

  test("parses a prerelease suffix", () => {
    expect(parseVersion("1.2.3-beta.1")).toEqual([1, 2, 3]);
  });

  test("accepts up to three digits per field", () => {
    expect(parseVersion("123.456.789")).toEqual([123, 456, 789]);
  });

  test("rejects fields wider than three digits", () => {
    expect(() => parseVersion("1234.0.0")).toThrow(/version/);
  });

  test("rejects a partial triple", () => {
    expect(() => parseVersion("1.2")).toThrow(/version/);
  });

  test("rejects non-numeric junk", () => {
    expect(() => parseVersion("not-a-version")).toThrow(/version/);
  });
});

describe("derivedBuildNumber", () => {
  test("packs three digits per semver field", () => {
    expect(derivedBuildNumber("0.2.9")).toBe("2009");
    expect(derivedBuildNumber("0.1.9")).toBe("1009");
    expect(derivedBuildNumber("0.2.0")).toBe("2000");
    expect(derivedBuildNumber("1.0.0")).toBe("1000000");
  });

  test("orders across field boundaries", () => {
    // 0.2.0 must sort above 0.1.9 — the whole point of three digits per field.
    expect(Number(derivedBuildNumber("0.2.0"))).toBeGreaterThan(
      Number(derivedBuildNumber("0.1.9")),
    );
  });

  test("ignores a prerelease suffix", () => {
    expect(derivedBuildNumber("0.2.9-beta.1")).toBe(
      derivedBuildNumber("0.2.9"),
    );
  });

  test("throws on a version it cannot parse", () => {
    expect(() => derivedBuildNumber("1.2")).toThrow(/build number/);
  });
});

describe("findIosVersion / setIosVersion", () => {
  const projectYml = [
    "targets:",
    "  Shidou:",
    "    settings:",
    "      base:",
    "        MARKETING_VERSION: 0.2.14",
    "        CURRENT_PROJECT_VERSION: 2014",
    "        INFOPLIST_KEY_CFBundleDisplayName: Shidou",
  ].join("\n");

  test("reads the marketing version", () => {
    expect(findIosVersion(projectYml)).toEqual({ line: 4, version: "0.2.14" });
  });

  test("rewrites the version and its derived build number in place", () => {
    const updated = setIosVersion(projectYml, "0.3.0");
    expect(updated).toContain("        MARKETING_VERSION: 0.3.0");
    expect(updated).toContain("        CURRENT_PROJECT_VERSION: 3000");
    expect(updated).toContain("INFOPLIST_KEY_CFBundleDisplayName: Shidou");
  });

  test("refuses a project without the build number key", () => {
    expect(() => setIosVersion("MARKETING_VERSION: 1.0.0\n", "1.0.1")).toThrow(
      /CURRENT_PROJECT_VERSION/,
    );
  });
});

describe("nextVersion", () => {
  test("bumps each level", () => {
    expect(nextVersion("0.2.14", "patch")).toBe("0.2.15");
    expect(nextVersion("0.2.14", "minor")).toBe("0.3.0");
    expect(nextVersion("0.2.14", "major")).toBe("1.0.0");
  });

  test("accepts an explicit later version and a prerelease promotion", () => {
    expect(nextVersion("0.2.14", "0.4.0")).toBe("0.4.0");
    expect(nextVersion("0.2.6-beta.1", "0.2.6")).toBe("0.2.6");
  });

  test("refuses the same or an older version", () => {
    expect(() => nextVersion("0.2.14", "0.2.14")).toThrow(/already/);
    expect(() => nextVersion("0.2.14", "0.2.9")).toThrow(/older/);
  });
});

import { describe, expect, test } from "bun:test";
import { channelPaths, filesForChannel, latestVersionTag } from "./channels";

describe("latestVersionTag", () => {
  test("picks the highest version, not the lexically last", () => {
    expect(
      latestVersionTag(["desktop/v0.2.9", "desktop/v0.2.14", "desktop/v0.2.10", "ios/v0.3.0"], "desktop/v"),
    ).toEqual({ tag: "desktop/v0.2.14", version: "0.2.14" });
  });

  test("ignores tags that are not versions", () => {
    expect(latestVersionTag(["desktop/vnext", "desktop/v"], "desktop/v")).toBeNull();
  });

  test("returns null with no tags", () => {
    expect(latestVersionTag([], "ios/v")).toBeNull();
  });
});

describe("filesForChannel", () => {
  const files = [
    "src/app.rs",
    "crates/shidou-core/src/server.rs",
    "apps/ios/App.swift",
    "apps/web/src/main.tsx",
    "website/src/index.tsx",
    "README.md",
    ".changes/x.md",
    "bun.lock",
  ];

  test("desktop ships its own code and shared code", () => {
    expect(filesForChannel(files, "desktop")).toEqual([
      "src/app.rs",
      "crates/shidou-core/src/server.rs",
      "bun.lock",
    ]);
  });

  test("browser ships apps/web and shared code", () => {
    expect(filesForChannel(files, "browser")).toEqual([
      "crates/shidou-core/src/server.rs",
      "apps/web/src/main.tsx",
      "bun.lock",
    ]);
  });

  test("website ships only website/", () => {
    expect(channelPaths("website")).toEqual(["website/"]);
    expect(filesForChannel(files, "website")).toEqual(["website/src/index.tsx"]);
  });
});

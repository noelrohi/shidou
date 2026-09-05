import { describe, expect, test } from "bun:test";
import { exportOptionsPlist, priorUpload, uploadKeyPaths } from "./ios-release";

describe("exportOptionsPlist", () => {
  test("targets App Store Connect with the team and automatic signing", () => {
    const plist = exportOptionsPlist({ teamId: "2Z79866758" });
    expect(plist).toContain("<key>method</key>");
    expect(plist).toContain("<string>app-store-connect</string>");
    expect(plist).toContain("<key>teamID</key>");
    expect(plist).toContain("<string>2Z79866758</string>");
    expect(plist).toContain("<string>automatic</string>");
    expect(plist).toContain("<key>stripSwiftSymbols</key>");
    expect(plist).toContain("<true/>");
  });

  test("manual mode pins the named profile and the distribution cert", () => {
    const plist = exportOptionsPlist({
      teamId: "2Z79866758",
      manual: { profile: "Shidou App Store" },
    });
    expect(plist).toContain("<string>manual</string>");
    expect(plist).toContain("<string>Apple Distribution</string>");
    expect(plist).toContain("<key>dev.shidou.ios</key>");
    expect(plist).toContain("<string>Shidou App Store</string>");
    expect(plist).not.toContain("automatic");
  });
});

describe("priorUpload", () => {
  const version = "0.2.13";
  const buildNumber = "2029";

  test("prefers an App Store Connect build", () => {
    expect(
      priorUpload(version, buildNumber, null, [
        { id: "older", version: "2028", processingState: "VALID" },
        { id: "current", version: buildNumber, processingState: "PROCESSING" },
      ]),
    ).toEqual({ id: "current", processingState: "PROCESSING" });
  });

  test("uses the local receipt while App Store Connect registers the upload", () => {
    expect(
      priorUpload(version, buildNumber, { version, buildNumber }, []),
    ).toEqual({ id: null, processingState: "PROCESSING" });
  });

  test("ignores receipts and builds for a different release", () => {
    expect(
      priorUpload(version, buildNumber, { version, buildNumber: "2028" }, [
        { id: "other", version: "2030", processingState: "VALID" },
      ]),
    ).toBeNull();
  });
});

describe("uploadKeyPaths", () => {
  test("returns every standard AuthKey search path for the key id", () => {
    const paths = uploadKeyPaths("ABC123");
    expect(paths).toContain("private_keys/AuthKey_ABC123.p8");
    expect(
      paths.some((p) =>
        p.endsWith("/.appstoreconnect/private_keys/AuthKey_ABC123.p8"),
      ),
    ).toBe(true);
    expect(
      paths.some((p) => p.endsWith("/private_keys/AuthKey_ABC123.p8")),
    ).toBe(true);
  });

  test("never treats the repository root as key storage", () => {
    expect(uploadKeyPaths("ABC123")).not.toContain("AuthKey_ABC123.p8");
  });
});

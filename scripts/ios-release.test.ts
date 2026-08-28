import { describe, expect, test } from "bun:test";
import { exportOptionsPlist, uploadKeyPaths } from "./ios-release";

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

  test("keeps the output deterministic", () => {
    const a = exportOptionsPlist({ teamId: "2Z79866758" });
    const b = exportOptionsPlist({ teamId: "2Z79866758" });
    expect(a).toBe(b);
  });
});

describe("uploadKeyPaths", () => {
  test("returns every standard AuthKey search path for the key id", () => {
    const paths = uploadKeyPaths("ABC123");
    expect(paths).toContain("AuthKey_ABC123.p8");
    expect(paths.some((p) => p.endsWith("/.appstoreconnect/private_keys/AuthKey_ABC123.p8"))).toBe(
      true,
    );
    expect(paths.some((p) => p.endsWith("/private_keys/AuthKey_ABC123.p8"))).toBe(true);
  });

  test("orders the cwd-relative path first", () => {
    expect(uploadKeyPaths("ABC123")[0]).toBe("AuthKey_ABC123.p8");
  });
});

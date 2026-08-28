#!/usr/bin/env bun

import { $ } from "bun";
import { copyFile, mkdir, readFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { derivedBuildNumber, findPackageVersion, parseVersion } from "./version";

const projectRoot = resolve(import.meta.dir, "..");
const manifestPath = join(projectRoot, "Cargo.toml");
const iosDir = join(projectRoot, "apps/ios");
const defaultOutputDir = join(projectRoot, "dist/ios");
const teamId = "2Z79866758";

const help = `Archive, export, and upload the iOS app for TestFlight.

Usage:
  bun run ios-release [options]

Steps, in order:
  1. Regenerate the Xcode project (xcodegen) and archive the Shidou scheme
     against Release for a generic iOS device, stamping MARKETING_VERSION
     and CURRENT_PROJECT_VERSION from Cargo.toml — the same source of truth
     as the desktop release.
  2. Verify the archive: the version keys took, export compliance and the
     local-networking ATS exemption survived into the built Info.plist, and
     the compiled app carries its asset catalogue. App Store Connect rejects
     an upload over any of these, and it says so only after the upload.
  3. --export: export a signed IPA (app-store-connect method). Needs an
     Apple Distribution certificate, or an App Store Connect API key so
     Xcode can create one.
  4. --upload: upload the IPA with altool (implies --export). Needs an
     App Store Connect API key.

Build numbers: ASC refuses a build number it has already seen for the same
marketing version. The default derives from the Cargo version (see
scripts/version.ts), which is right for the first upload of a version; for
a re-upload, pass an explicit increasing --build-number. See
docs/releasing-ios.md for the dashboard steps this script cannot do.

Options:
  --export               Export a signed IPA after archiving
  --upload               Upload the IPA to App Store Connect (implies --export)
  --build-number <n>     CURRENT_PROJECT_VERSION override (or
                         SHIDOU_BUILD_NUMBER); default derives from Cargo.toml
  --output <dir>         Output directory (default: dist/ios)
  --api-key-id <id>      ASC API key id (or SHIDOU_ASC_API_KEY_ID)
  --api-issuer <id>      ASC API issuer id (or SHIDOU_ASC_API_ISSUER_ID)
  --api-key-path <path>  Path to the AuthKey_<id>.p8 file (or
                         SHIDOU_ASC_API_KEY_PATH); copied into ./private_keys,
                         where altool looks for it
  --help                 Show this help

Environment:
  SHIDOU_ASC_API_KEY_ID / SHIDOU_ASC_API_ISSUER_ID / SHIDOU_ASC_API_KEY_PATH
  SHIDOU_BUILD_NUMBER
`;

/** ExportOptions.plist for the IPA export. Pure, and exported for tests. */
export function exportOptionsPlist(options: { teamId: string }): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>teamID</key>
	<string>${options.teamId}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
</dict>
</plist>
`;
}

/** The paths altool searches for `AuthKey_<id>.p8`, cwd-relative first. */
export function uploadKeyPaths(keyId: string): string[] {
  const home = homedir();
  const name = `AuthKey_${keyId}.p8`;
  return [
    name,
    join("private_keys", name),
    join(home, "private_keys", name),
    join(home, ".private_keys", name),
    join(home, ".appstoreconnect", "private_keys", name),
  ];
}

function requireTool(name: string): void {
  if (!Bun.which(name)) {
    throw new Error(`Required tool not found in PATH: ${name}`);
  }
}

function logStep(message: string): void {
  console.log(`\n==> ${message}`);
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    args: Bun.argv.slice(2),
    options: {
      "api-issuer": { type: "string" },
      "api-key-id": { type: "string" },
      "api-key-path": { type: "string" },
      "build-number": { type: "string" },
      export: { type: "boolean" },
      help: { type: "boolean", short: "h" },
      output: { type: "string" },
      upload: { type: "boolean" },
    },
    strict: true,
  });

  if (values.help) {
    console.log(help);
    process.exit(0);
  }

  const uploading = values.upload ?? false;
  const exporting = values.export ?? false;
  const outputDir = values.output ? resolve(values.output) : defaultOutputDir;
  const explicitBuildNumber =
    values["build-number"] ?? process.env.SHIDOU_BUILD_NUMBER;
  const apiKeyId = values["api-key-id"] ?? process.env.SHIDOU_ASC_API_KEY_ID;
  const apiIssuer =
    values["api-issuer"] ?? process.env.SHIDOU_ASC_API_ISSUER_ID;
  const apiKeyPath =
    values["api-key-path"] ?? process.env.SHIDOU_ASC_API_KEY_PATH;

  if (uploading && (!apiKeyId || !apiIssuer)) {
    throw new Error(
      "--upload needs an App Store Connect API key: pass --api-key-id and " +
        "--api-issuer (or set SHIDOU_ASC_API_KEY_ID / SHIDOU_ASC_API_ISSUER_ID).",
    );
  }
  if (apiKeyPath && !apiKeyId) {
    throw new Error(
      "--api-key-path needs --api-key-id so the key can be filed under its " +
        "AuthKey_<id>.p8 name.",
    );
  }
  if (explicitBuildNumber && !/^\d+(?:\.\d+){0,2}$/.test(explicitBuildNumber)) {
    throw new Error(
      "--build-number must contain one to three period-separated integers.",
    );
  }

  /** First existing standard location for the API key, or null. */
  function findApiKey(): string | null {
    if (!apiKeyId) return null;
    if (apiKeyPath) {
      const absolute = resolve(apiKeyPath);
      return existsSync(absolute) ? absolute : null;
    }
    return (
      // Skip the bare filename entry — only directory paths are real search
      // locations for an existing key.
      uploadKeyPaths(apiKeyId).find((p) => p.includes("/") && existsSync(p)) ??
      null
    );
  }

  /** xcodebuild's authentication flags. Without an API key it still passes
   *  -allowProvisioningUpdates, which works when a distribution certificate
   *  already exists in the keychain. */
  function xcodebuildAuth(): string[] {
    const key = findApiKey();
    if (!apiKeyId || !apiIssuer || !key) return ["-allowProvisioningUpdates"];
    return [
      "-allowProvisioningUpdates",
      "-authenticationKeyID",
      apiKeyId,
      "-authenticationKeyIssuer",
      apiIssuer,
      "-authenticationKeyPath",
      key,
    ];
  }

  const manifest = await readFile(manifestPath, "utf8");
  const version = findPackageVersion(manifest).version;
  parseVersion(version); // Fail on a malformed version before building anything.
  const buildNumber = explicitBuildNumber ?? derivedBuildNumber(version);

  logStep(`Building Shidou iOS ${version} (build ${buildNumber})`);
  requireTool("xcodegen");
  await $`cd ${iosDir} && xcodegen generate`;

  // An incomplete asset catalogue fails at upload — minutes after the build —
  // not at build time, so check the icon exists before spending the archive.
  const appiconset = join(
    iosDir,
    "Shidou/Resources/Assets.xcassets/AppIcon.appiconset",
  );
  const appiconContents = JSON.parse(
    await Bun.file(join(appiconset, "Contents.json")).text(),
  ) as { images?: Array<{ filename?: string; size?: string }> };
  for (const image of appiconContents.images ?? []) {
    if (!image.filename) {
      throw new Error(
        `The AppIcon.appiconset is missing an image for size ${image.size ?? "?"}.`,
      );
    }
    await stat(join(appiconset, image.filename)); // Throws if the file is absent.
  }

  const archivePath = join(outputDir, "Shidou.xcarchive");
  await mkdir(outputDir, { recursive: true });
  await $`xcodebuild -project ${join(iosDir, "Shidou.xcodeproj")} -scheme Shidou -configuration Release -destination "generic/platform=iOS" -archivePath ${archivePath} MARKETING_VERSION=${version} CURRENT_PROJECT_VERSION=${buildNumber} ${xcodebuildAuth()} archive`;

  logStep("Verifying the archive");
  const appPath = join(archivePath, "Products/Applications/Shidou.app");
  const plistPath = join(appPath, "Info.plist");

  async function plistValue(key: string): Promise<string> {
    const result = await $`plutil -extract ${key} raw -o - ${plistPath}`
      .quiet()
      .nothrow();
    return result.stdout.toString().trim();
  }

  const checks: Array<[string, string, string]> = [
    ["CFBundleShortVersionString", version, "marketing version"],
    ["CFBundleVersion", buildNumber, "build number"],
    ["ITSAppUsesNonExemptEncryption", "false", "export compliance"],
    ["NSAppTransportSecurity.NSAllowsLocalNetworking", "true", "ATS exemption"],
  ];
  let verificationFailed = false;
  for (const [key, expected, label] of checks) {
    const actual = await plistValue(key);
    if (actual === expected) {
      console.log(`  ok   ${label}: ${key} = ${expected}`);
    } else {
      verificationFailed = true;
      console.log(
        `  FAIL ${label}: ${key} = ${actual || "(missing)"}, expected ${expected}`,
      );
    }
  }
  if (!existsSync(join(appPath, "Assets.car"))) {
    verificationFailed = true;
    console.log("  FAIL Assets.car is missing from the built app");
  }
  if (verificationFailed) {
    throw new Error(
      "The archive failed verification; not exporting or uploading. " +
        "Check apps/ios/project.yml.",
    );
  }

  const ipaPath = join(outputDir, "Shidou.ipa");

  if (!exporting && !uploading) {
    console.log(
      `\nArchive verified at ${archivePath}.\n` +
        "Pass --export to produce an IPA, or --upload to send it to TestFlight.",
    );
    process.exit(0);
  }

  logStep("Exporting the IPA");
  const exportOptionsPath = join(outputDir, "ExportOptions.plist");
  await Bun.write(exportOptionsPath, exportOptionsPlist({ teamId }));
  await $`xcodebuild -exportArchive -archivePath ${archivePath} -exportOptionsPlist ${exportOptionsPath} -exportPath ${outputDir} ${xcodebuildAuth()}`;

  if (!uploading) {
    console.log(
      `\nExported ${ipaPath}. Upload with --upload, or drag it into ` +
        "Transporter / Xcode Organizer.",
    );
    process.exit(0);
  }

  logStep("Uploading to App Store Connect");
  if (!apiKeyId || !apiIssuer) {
    throw new Error("Upload requires an App Store Connect API key.");
  }
  // altool has no --api-key-path flag; it searches ./private_keys first.
  if (apiKeyPath) {
    await mkdir("private_keys", { recursive: true });
    await copyFile(resolve(apiKeyPath), uploadKeyPaths(apiKeyId)[0]!);
  }
  if (!findApiKey()) {
    throw new Error(
      `AuthKey_${apiKeyId}.p8 not found in any standard location ` +
        `(${uploadKeyPaths(apiKeyId).join(", ")}); pass --api-key-path.`,
    );
  }
  await $`xcrun altool --upload-app --type ios -f ${ipaPath} --apiKey ${apiKeyId} --apiIssuer ${apiIssuer}`;

  console.log(
    `\nShidou iOS ${version} (build ${buildNumber}) uploaded. App Store Connect ` +
      "takes a few minutes to process it; then add it to an internal tester " +
      "group. See docs/releasing-ios.md for the dashboard steps.",
  );
}

// Only the pure helpers above are imported by tests; the pipeline runs only
// when this file is the entry point.
if (import.meta.main) {
  await main();
}

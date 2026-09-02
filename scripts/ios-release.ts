#!/usr/bin/env bun

import { $ } from "bun";
import { mkdir, readFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import {
  derivedBuildNumber,
  findIosVersion,
  nextIosBuildNumber,
  parseVersion,
} from "./version";
import { AscApi } from "./asc";

const projectRoot = resolve(import.meta.dir, "..");
const iosDir = join(projectRoot, "apps/ios");
const iosProjectYmlPath = join(iosDir, "project.yml");
const defaultOutputDir = join(projectRoot, "dist/ios");
const teamId = "2Z79866758";
const appBundleId = "dev.shidou.ios";

const help = `Archive, export, and upload the iOS app for TestFlight.

Usage:
  bun run ios-release [options]

Steps, in order:
  1. Regenerate the Xcode project (xcodegen) and archive the Shidou scheme
     against Release for a generic iOS device, stamping MARKETING_VERSION
     from apps/ios/project.yml and CURRENT_PROJECT_VERSION from the selected
     build number.
  2. Verify the archive: the version keys took, export compliance and the
     local-networking ATS exemption survived into the built Info.plist, and
     the compiled app carries its asset catalogue. App Store Connect rejects
     an upload over any of these, and it says so only after the upload.
  3. --create-app-record (also run by --upload): find or create the App
     Store Connect app record via the API — bundle id registered if needed,
     name and primary locale set. The only dashboard work left after this
     is the API key itself and the internal tester group.
  4. --export: export a signed IPA (app-store-connect method). Needs an
     Apple Distribution certificate, or an App Store Connect API key so
     Xcode can create one.
  5. --upload: upload the IPA with altool (implies --export). Needs an
     App Store Connect API key.

Build numbers: ASC requires them to increase across the app. The default
derives from the iOS marketing version (see scripts/version.ts); use
--next-build-number to ask ASC for the highest uploaded build and go one
higher, or pass --build-number explicitly. See docs/releasing-ios.md for
the dashboard steps this script cannot do.

Options:
  --export               Export a signed IPA after archiving
  --upload               Upload the IPA to App Store Connect (implies --export)
  --create-app-record    Create the App Store Connect app record if missing;
                         also runs automatically before --upload
  --app-name <name>      App Store name (default: Shidou) — must be unique
                         across the App Store
  --primary-locale <l>   Primary locale (default: en-US)
  --build-number <n>     CURRENT_PROJECT_VERSION override (or
                         SHIDOU_BUILD_NUMBER); default derives from the
                         iOS version
  --next-build-number    Ask App Store Connect for the highest build number
                         uploaded across all marketing versions and use the
                         next one (needs the API key)
  --print-next-build-number
                         Print that number without building; used by
                         \`bun run ship ios\` to plan its Delivery Record
  --wait                 After --upload, poll App Store Connect until the
                         build is VALID and in internal testing, so the
                         command ends only when testers can install it
  --output <dir>         Output directory (default: dist/ios)
  --api-key-id <id>      ASC API key id (or SHIDOU_ASC_API_KEY_ID)
  --api-issuer <id>      ASC API issuer id (or SHIDOU_ASC_API_ISSUER_ID)
  --api-key-path <path>  Path to the AuthKey_<id>.p8 file (or
                         SHIDOU_ASC_API_KEY_PATH); altool reads it in place
  --profile <name>       Export with manual signing against this provisioning
                         profile (App Store type; or SHIDOU_IOS_PROFILE).
                         Needed when cloud signing is
                         unavailable — Apple does not serve profile content to
                         API keys, so the profile must be installed locally by
                         Xcode (Settings → Accounts → team → Download Manual
                         Profiles).
  --help                 Show this help

Environment:
  SHIDOU_ASC_API_KEY_ID / SHIDOU_ASC_API_ISSUER_ID / SHIDOU_ASC_API_KEY_PATH
  SHIDOU_BUILD_NUMBER
  SHIDOU_IOS_PROFILE
`;

/** ExportOptions.plist for the IPA export. Pure, and exported for tests.
 *  `manual` switches to a named App Store profile — the escape hatch when
 *  cloud signing is unavailable (Apple does not serve profile content to
 *  API keys, so the profile must be installed locally by Xcode). */
export function exportOptionsPlist(options: {
  teamId: string;
  manual?: { profile: string };
}): string {
  const manualKeys = options.manual
    ? `\t<key>signingStyle</key>\n\t<string>manual</string>\n\t<key>signingCertificate</key>\n\t<string>Apple Distribution</string>\n\t<key>provisioningProfiles</key>\n\t<dict>\n\t\t<key>dev.shidou.ios</key>\n\t\t<string>${options.manual.profile}</string>\n\t</dict>\n`
    : `\t<key>signingStyle</key>\n\t<string>automatic</string>\n`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>method</key>
\t<string>app-store-connect</string>
\t<key>teamID</key>
\t<string>${options.teamId}</string>
${manualKeys}\t<key>stripSwiftSymbols</key>
\t<true/>
</dict>
</plist>
`;
}

/** The standard directories altool searches for `AuthKey_<id>.p8`. */
export function uploadKeyPaths(keyId: string): string[] {
  const home = homedir();
  const name = `AuthKey_${keyId}.p8`;
  return [
    join("private_keys", name),
    join(home, "private_keys", name),
    join(home, ".private_keys", name),
    join(home, ".appstoreconnect", "private_keys", name),
  ];
}

type UploadedBuild = { id: string; version: string; processingState: string };
type UploadReceipt = { version: string; buildNumber: string };

/** An upload that can be resumed without rebuilding. ASC is authoritative
 *  once it knows the build; the receipt covers its post-upload registration
 *  delay. */
export function priorUpload(
  version: string,
  buildNumber: string,
  receipt: UploadReceipt | null,
  builds: UploadedBuild[],
): { id: string | null; processingState: string } | null {
  const build = builds.find((candidate) => candidate.version === buildNumber);
  if (build) return { id: build.id, processingState: build.processingState };
  if (receipt?.version === version && receipt.buildNumber === buildNumber) {
    return { id: null, processingState: "PROCESSING" };
  }
  return null;
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
      "app-name": { type: "string" },
      "build-number": { type: "string" },
      "create-app-record": { type: "boolean" },
      export: { type: "boolean" },
      "next-build-number": { type: "boolean" },
      "print-next-build-number": { type: "boolean" },
      wait: { type: "boolean" },
      help: { type: "boolean", short: "h" },
      output: { type: "string" },
      "primary-locale": { type: "string" },
      profile: { type: "string" },
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
  const waiting = values.wait ?? false;
  const printNextBuildNumber = values["print-next-build-number"] ?? false;
  const nextBuildNumber =
    (values["next-build-number"] ?? false) || printNextBuildNumber;
  const profile = values.profile ?? process.env.SHIDOU_IOS_PROFILE;
  const ensureAppRecord = uploading || (values["create-app-record"] ?? false);
  const appName = values["app-name"] ?? "Shidou";
  const primaryLocale = values["primary-locale"] ?? "en-US";
  const outputDir = values.output ? resolve(values.output) : defaultOutputDir;
  const explicitBuildNumber =
    values["build-number"] ?? process.env.SHIDOU_BUILD_NUMBER;
  const apiKeyId = values["api-key-id"] ?? process.env.SHIDOU_ASC_API_KEY_ID;
  const apiIssuer =
    values["api-issuer"] ?? process.env.SHIDOU_ASC_API_ISSUER_ID;
  const apiKeyPathRaw =
    values["api-key-path"] ?? process.env.SHIDOU_ASC_API_KEY_PATH;
  // Wizards and shells love to hand us a literal `~`, which existsSync and
  // copyFile will never expand.
  const apiKeyPath = apiKeyPathRaw?.startsWith("~/")
    ? join(homedir(), apiKeyPathRaw.slice(2))
    : apiKeyPathRaw;

  if (ensureAppRecord && (!apiKeyId || !apiIssuer)) {
    throw new Error(
      "--upload/--create-app-record need an App Store Connect API key: pass " +
        "--api-key-id and --api-issuer (or set SHIDOU_ASC_API_KEY_ID / " +
        "SHIDOU_ASC_API_ISSUER_ID). Create one in ASC under Users and Access " +
        "→ Integrations, with the App Manager role.",
    );
  }
  if (apiKeyPath && !apiKeyId) {
    throw new Error("--api-key-path needs --api-key-id.");
  }
  if (
    apiKeyPath &&
    apiKeyId &&
    basename(apiKeyPath) !== `AuthKey_${apiKeyId}.p8`
  ) {
    throw new Error(
      `--api-key-path must point to AuthKey_${apiKeyId}.p8 so altool can find it.`,
    );
  }
  if (explicitBuildNumber && !/^\d+(?:\.\d+){0,2}$/.test(explicitBuildNumber)) {
    throw new Error(
      "--build-number must contain one to three period-separated integers.",
    );
  }
  if (nextBuildNumber && explicitBuildNumber) {
    throw new Error(
      "Use either --next-build-number or --build-number, not both.",
    );
  }
  if ((nextBuildNumber || waiting) && (!apiKeyId || !apiIssuer)) {
    throw new Error(
      "--next-build-number and --wait need an App Store Connect API key.",
    );
  }
  if (waiting && !uploading) {
    throw new Error("--wait only makes sense with --upload.");
  }

  /** First existing standard location for the API key, or null. */
  function findApiKey(): string | null {
    if (!apiKeyId) return null;
    if (apiKeyPath) {
      const absolute = resolve(apiKeyPath);
      return existsSync(absolute) ? absolute : null;
    }
    return uploadKeyPaths(apiKeyId).find((path) => existsSync(path)) ?? null;
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
      "-authenticationKeyIssuerID",
      apiIssuer,
      "-authenticationKeyPath",
      key,
    ];
  }

  const version = findIosVersion(
    await readFile(iosProjectYmlPath, "utf8"),
  ).version;
  parseVersion(version); // Fail on a malformed version before building anything.

  /** An authenticated ASC client, or an error naming the missing key. */
  async function ascClient(): Promise<AscApi> {
    const keyPath = findApiKey();
    if (!keyPath) {
      throw new Error(
        `AuthKey_${apiKeyId}.p8 not found in any standard location ` +
          `(${uploadKeyPaths(apiKeyId!).join(", ")}); pass --api-key-path.`,
      );
    }
    return new AscApi(apiKeyId!, apiIssuer!, await Bun.file(keyPath).text());
  }

  /** The app record id, required by the builds endpoints. */
  async function appRecordId(asc: AscApi): Promise<string> {
    const app = await asc.findAppByBundleId(appBundleId);
    if (!app) {
      throw new Error(
        `No App Store Connect app record for ${appBundleId}; run with --create-app-record first.`,
      );
    }
    return app.id;
  }

  let buildNumber = explicitBuildNumber ?? derivedBuildNumber(version);
  if (nextBuildNumber) {
    // ASC is the source of truth because build numbers increase across the
    // app, including when the marketing version changes.
    const asc = await ascClient();
    const builds = await asc.listBuilds(await appRecordId(asc));
    buildNumber = nextIosBuildNumber(
      version,
      builds.map((build) => build.version),
    );
    const highest = builds
      .map((build) => Number(build.version))
      .filter(Number.isSafeInteger)
      .reduce((max, build) => Math.max(max, build), 0);
    if (!printNextBuildNumber) {
      console.log(
        highest > 0
          ? `  ok   ASC has build ${highest}; using ${buildNumber}.`
          : `  ok   ASC has no builds yet; using ${buildNumber}.`,
      );
    }
  }
  if (printNextBuildNumber) {
    console.log(buildNumber);
    return;
  }

  /** Find-or-create the ASC app record, idempotently. Creates nothing when
   *  the record already exists, so uploads stay repeatable. */
  async function ensureAppRecordExists(asc: AscApi): Promise<string> {
    const existing = await asc.findAppByBundleId(appBundleId);
    if (existing) {
      console.log(
        `  ok   App Store Connect app record already exists (${existing.id}).`,
      );
      return existing.id;
    }
    logStep(
      `Creating the App Store Connect app record for ${appBundleId} ` +
        `("${appName}", ${primaryLocale})`,
    );
    if (!(await asc.findBundleId(appBundleId))) {
      await asc.registerBundleId(appBundleId);
    }
    let created: { id: string };
    try {
      created = await asc.createApp({
        name: appName,
        sku: appBundleId,
        primaryLocale,
        bundleId: appBundleId,
      });
    } catch (error) {
      // App Manager keys can manage but not create apps; only Admin and
      // Account Holder keys get CREATE on 'apps'.
      if (/does not allow 'CREATE'/i.test(String(error))) {
        throw new Error(
          `This API key's role cannot create apps. Either create the record ` +
            `by hand (App Store Connect → Apps → + → New App: iOS, name ` +
            `"${appName}", bundle ${appBundleId}, English (U.S.)) or raise ` +
            `the key to Admin, then re-run.`,
        );
      }
      throw error;
    }
    console.log(`  ok   App record created (${created.id}).`);
    return created.id;
  }

  async function waitForUploadedBuild(
    asc: AscApi,
    appId: string,
  ): Promise<void> {
    logStep(`Waiting for App Store Connect to process build ${buildNumber}`);
    const deadline = Date.now() + 45 * 60 * 1000;
    let buildId: string | null = null;
    while (Date.now() < deadline) {
      const build = (await asc.listBuilds(appId, { version })).find(
        (candidate) => candidate.version === buildNumber,
      );
      if (build?.processingState === "VALID") {
        buildId = build.id;
        break;
      }
      if (build && build.processingState !== "PROCESSING") {
        throw new Error(
          `App Store Connect reports build ${buildNumber} as ${build.processingState}.`,
        );
      }
      console.log(
        `  ..   ${build ? build.processingState : "not registered yet"}`,
      );
      await Bun.sleep(30_000);
    }
    if (!buildId) {
      throw new Error(
        `Build ${buildNumber} was still processing after 45 minutes; check App Store Connect.`,
      );
    }
    while (Date.now() < deadline) {
      const state = await asc.buildBetaState(buildId);
      if (state === "IN_BETA_TESTING") return;
      console.log(`  ..   internal testing: ${state ?? "unknown"}`);
      await Bun.sleep(30_000);
    }
    throw new Error(
      `Build ${buildNumber} was not available to internal testers after 45 minutes.`,
    );
  }

  const receiptPath = join(outputDir, "upload-receipt.json");
  let uploadAsc: AscApi | null = null;
  let uploadAppId: string | null = null;
  if (uploading) {
    uploadAsc = await ascClient();
    uploadAppId = await ensureAppRecordExists(uploadAsc);
    const receipt = existsSync(receiptPath)
      ? ((await Bun.file(receiptPath)
          .json()
          .catch(() => null)) as UploadReceipt | null)
      : null;
    const uploaded = priorUpload(
      version,
      buildNumber,
      receipt,
      await uploadAsc.listBuilds(uploadAppId, { version }),
    );
    if (uploaded) {
      if (
        uploaded.processingState !== "PROCESSING" &&
        uploaded.processingState !== "VALID"
      ) {
        throw new Error(
          `App Store Connect reports build ${buildNumber} as ${uploaded.processingState}.`,
        );
      }
      console.log(
        `  ok   iOS ${version} (build ${buildNumber}) was already uploaded; skipping archive and upload.`,
      );
      if (waiting) {
        await waitForUploadedBuild(uploadAsc, uploadAppId);
        console.log(
          `\nShidou iOS ${version} (build ${buildNumber}) is VALID and in internal testing.`,
        );
      }
      return;
    }
  }

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
  await Bun.write(
    exportOptionsPath,
    profile
      ? exportOptionsPlist({ teamId, manual: { profile } })
      : exportOptionsPlist({ teamId }),
  );
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
  const uploadKeyPath = findApiKey();
  if (!uploadKeyPath) {
    throw new Error(
      `AuthKey_${apiKeyId}.p8 not found in any standard location ` +
        `(${uploadKeyPaths(apiKeyId).join(", ")}); pass --api-key-path.`,
    );
  }
  // altool has no path flag, but it honors API_PRIVATE_KEYS_DIR. Point it at
  // the configured key instead of copying a credential into the repository.
  await $`xcrun altool --upload-app --type ios -f ${ipaPath} --apiKey ${apiKeyId} --apiIssuer ${apiIssuer}`.env(
    {
      ...process.env,
      API_PRIVATE_KEYS_DIR: dirname(resolve(uploadKeyPath)),
    },
  );
  await Bun.write(
    receiptPath,
    `${JSON.stringify({ version, buildNumber }, null, 2)}\n`,
  );

  if (!waiting) {
    console.log(
      `\nShidou iOS ${version} (build ${buildNumber}) uploaded. App Store Connect ` +
        "takes a few minutes to process it; the internal tester group receives " +
        "it automatically. Pass --wait to block until then.",
    );
    return;
  }

  // Upload ≠ available. The iOS Release counts as shipped only when internal
  // testers can install it, so poll until ASC says so. The first checks often
  // come back empty while the upload is still being registered.
  await waitForUploadedBuild(uploadAsc!, uploadAppId!);
  console.log(
    `\nShidou iOS ${version} (build ${buildNumber}) is VALID and in internal testing.`,
  );
}

// Only the pure helpers above are imported by tests; the pipeline runs only
// when this file is the entry point.
if (import.meta.main) {
  await main();
}

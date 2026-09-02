/** Release version helpers shared by the desktop and iOS release scripts.
 *  Cargo.toml's root `[package]` version is the Desktop version and
 *  apps/ios/project.yml's MARKETING_VERSION the iOS one (ADR 0004);
 *  `bun run bump --app <desktop|ios>` is the only thing that writes them. */

/** The `version` line of the root `[package]` table. Later tables carry their
 *  own `version` keys (dependencies, metadata), so the search stops at the
 *  next table header rather than taking the first match in the file. */
export function findPackageVersion(manifest: string): {
  line: number;
  version: string;
} {
  const lines = manifest.split("\n");
  let inPackage = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    if (/^\s*\[/.test(line)) {
      inPackage = /^\s*\[package\]\s*$/.test(line);
      continue;
    }
    if (!inPackage) continue;
    const match = line.match(/^\s*version\s*=\s*"([^"]+)"\s*$/);
    if (match?.[1]) return { line: i, version: match[1] };
  }
  throw new Error("No `version` key in the root [package] table of Cargo.toml.");
}

// Three fields of at most three digits, plus an optional prerelease tag —
// the widest shape this project releases.
const versionPattern = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:-([0-9A-Za-z.-]+))?$/;

export function parseVersion(version: string): [number, number, number] {
  const match = version.match(versionPattern);
  if (!match) {
    throw new Error(
      `"${version}" is not a version this project can release. Use ` +
        "major.minor.patch, each at most three digits, with an optional " +
        "-prerelease suffix.",
    );
  }
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

/** CFBundleVersion / build number derived from the Cargo version. Both
 *  Sparkle (desktop) and App Store Connect (iOS) decide which of two builds
 *  is newer by comparing this value, so it must grow with every release:
 *  three digits per semver field keep 0.2.0 → 2000 ahead of 0.1.9 → 1009,
 *  and every release ahead of the pre-Sparkle DMGs that shipped
 *  CFBundleVersion 1. */
export function derivedBuildNumber(version: string): string {
  try {
    const [major, minor, patch] = parseVersion(version);
    return String(major * 1_000_000 + minor * 1_000 + patch);
  } catch {
    throw new Error(
      `Cannot derive a build number from version "${version}"; ` +
        "pass --build-number.",
    );
  }
}

/** Pick the next TestFlight build number. App Store Connect requires build
 *  numbers to increase across the app, not merely within one marketing
 *  version, so every uploaded build participates in the maximum. */
export function nextIosBuildNumber(
  marketingVersion: string,
  uploadedBuildNumbers: string[],
): string {
  const highestUploaded = uploadedBuildNumbers
    .map(Number)
    .filter(Number.isSafeInteger)
    .reduce((highest, build) => Math.max(highest, build), 0);
  return String(
    Math.max(highestUploaded + 1, Number(derivedBuildNumber(marketingVersion))),
  );
}

/** The iOS marketing version from `apps/ios/project.yml`. The iOS Client has
 *  its own release line (see docs/adr/0004-independent-delivery-channels.md),
 *  so its version lives beside the Xcode project rather than in Cargo.toml. */
export function findIosVersion(projectYml: string): { line: number; version: string } {
  const lines = projectYml.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const match = lines[i]?.match(/^\s*MARKETING_VERSION:\s*(\S+)\s*$/);
    if (match?.[1]) return { line: i, version: match[1].replace(/^["']|["']$/g, "") };
  }
  throw new Error("No MARKETING_VERSION in apps/ios/project.yml.");
}

/** Rewrite the iOS marketing version and advance its build baseline in
 *  `project.yml`. Both keys must exist: a silent no-op would ship stale data. */
export function setIosVersion(projectYml: string, version: string): string {
  const { line } = findIosVersion(projectYml);
  const lines = projectYml.split("\n");
  const indent = lines[line]!.match(/^\s*/)![0];
  lines[line] = `${indent}MARKETING_VERSION: ${version}`;
  const buildLine = lines.findIndex((entry) => /^\s*CURRENT_PROJECT_VERSION:/.test(entry));
  if (buildLine === -1) {
    throw new Error("No CURRENT_PROJECT_VERSION in apps/ios/project.yml.");
  }
  const buildIndent = lines[buildLine]!.match(/^\s*/)![0];
  const currentBuild = lines[buildLine]!.match(
    /^\s*CURRENT_PROJECT_VERSION:\s*(\S+)\s*$/,
  )?.[1];
  if (!currentBuild) {
    throw new Error("CURRENT_PROJECT_VERSION has no build number in apps/ios/project.yml.");
  }
  lines[buildLine] = `${buildIndent}CURRENT_PROJECT_VERSION: ${nextIosBuildNumber(version, [currentBuild])}`;
  return lines.join("\n");
}

/** The next version after `current` for a bump level, or an explicit
 *  version, refusing anything that would move backwards. Only the numeric
 *  triple is compared, so promoting a prerelease (0.2.6-beta.1 → 0.2.6)
 *  passes. */
export function nextVersion(current: string, requested: string): string {
  const [major, minor, patch] = parseVersion(current);
  let version: string;
  switch (requested) {
    case "major":
      version = `${major + 1}.0.0`;
      break;
    case "minor":
      version = `${major}.${minor + 1}.0`;
      break;
    case "patch":
      version = `${major}.${minor}.${patch + 1}`;
      break;
    default:
      version = requested;
  }
  const target = parseVersion(version);
  const source = [major, minor, patch];
  if (version === current) {
    throw new Error(`The version is already ${version}.`);
  }
  for (let field = 0; field < 3; field++) {
    if (target[field]! > source[field]!) break;
    if (target[field]! < source[field]!) {
      throw new Error(
        `${version} is older than the current ${current}. Build numbers derive ` +
          "from the version, so versions only move forward.",
      );
    }
  }
  return version;
}

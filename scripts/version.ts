/** Release version helpers shared by the desktop and iOS release scripts.
 *  Cargo.toml's root `[package]` version is the single source of truth for
 *  both; `bun run bump` is the only thing that writes it. */

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

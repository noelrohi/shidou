import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const action = Bun.YAML.parse(
  readFileSync(join(root, ".github/actions/setup-rust/action.yml"), "utf8"),
) as { runs: { using: string; steps: { shell: string; run: string }[] } };

function setup(
  installed: string[],
  host = "aarch64-apple-darwin",
  environment = "github-hosted",
  githubActions = "true",
) {
  const dir = mkdtempSync(join(tmpdir(), "shidou-rust-setup-"));
  try {
    writeFileSync(join(dir, "toolchains"), installed.join("\n") + "\n");
    // Only this fake receives rustup commands; no local Rust state is read or changed.
    writeFileSync(join(dir, "rustup"), `#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_DIR/calls"
state="$FAKE_DIR/toolchains"
pinned="1.96.0-$FAKE_HOST"
case "$*" in
  'toolchain install 1.96.0 --profile minimal')
    grep -Fxq "$pinned" "$state" || echo "$pinned" >> "$state" ;;
  'default 1.96.0')
    grep -Fxq "$pinned" "$state" ;;
  'toolchain list')
    while read -r toolchain; do
      if [[ "$toolchain" == "$pinned" ]]; then
        printf '%s (active, default)\\r\\n' "$toolchain"
      else
        printf '%s\\r\\n' "$toolchain"
      fi
    done < "$state" ;;
  'toolchain uninstall '*)
    grep -Fxv "$3" "$state" > "$state.next"
    mv "$state.next" "$state" ;;
  *) echo "Unexpected rustup command: $*" >&2; exit 1 ;;
esac
`, { mode: 0o755 });
    expect(action.runs.using).toBe("composite");
    expect(action.runs.steps).toHaveLength(1);
    expect(action.runs.steps[0].shell).toBe("bash");
    const result = Bun.spawnSync(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", action.runs.steps[0].run], {
      cwd: dir,
      env: {
        PATH: `${dir}:/usr/bin:/bin`,
        GITHUB_ACTIONS: githubActions,
        RUNNER_ENVIRONMENT: environment,
        FAKE_DIR: dir,
        FAKE_HOST: host,
      },
    });
    expect(result.stderr.toString()).toBe("");
    expect(result.exitCode).toBe(0);
    return {
      retained: readFileSync(join(dir, "toolchains"), "utf8").trim().split("\n"),
      calls: readFileSync(join(dir, "calls"), "utf8").trim().split("\n"),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("different unused macOS toolchains converge to the same rust-cache inventory", () => {
  for (const version of ["1.97.0", "1.98.0"]) {
    const unused = [`${version}-aarch64-apple-darwin`, "stable-aarch64-apple-darwin", "nightly-aarch64-apple-darwin"];
    const result = setup([unused[0], "1.96.0-aarch64-apple-darwin", ...unused.slice(1)]);
    expect(result.retained).toEqual(["1.96.0-aarch64-apple-darwin"]);
    expect(result.calls).toEqual([
      "toolchain install 1.96.0 --profile minimal",
      "default 1.96.0",
      "toolchain list",
      ...unused.map((toolchain) => `toolchain uninstall ${toolchain}`),
    ]);
  }
});

test("installs the pin before removing preinstalled toolchains", () => {
  const result = setup(["stable-aarch64-apple-darwin"]);
  expect(result.retained).toEqual(["1.96.0-aarch64-apple-darwin"]);
  expect(result.calls).toEqual([
    "toolchain install 1.96.0 --profile minimal",
    "default 1.96.0",
    "toolchain list",
    "toolchain uninstall stable-aarch64-apple-darwin",
  ]);
});

test("pinned-only installations are retained without uninstalling or duplicating them", () => {
  for (const host of ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu", "x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"]) {
    const pinned = `1.96.0-${host}`;
    const result = setup([pinned], host);
    expect(result.retained).toEqual([pinned]);
    expect(result.calls).toEqual([
      "toolchain install 1.96.0 --profile minimal",
      "default 1.96.0",
      "toolchain list",
    ]);
  }
});

test("local and self-hosted runs never prune installed toolchains", () => {
  for (const [environment, githubActions] of [["", ""], ["self-hosted", "true"], ["github-hosted", ""]]) {
    const installed = ["stable-aarch64-apple-darwin", "1.96.0-aarch64-apple-darwin"];
    const result = setup(installed, "aarch64-apple-darwin", environment, githubActions);
    expect(result.retained).toEqual(installed);
    expect(result.calls).toEqual([
      "toolchain install 1.96.0 --profile minimal",
      "default 1.96.0",
    ]);
  }
});

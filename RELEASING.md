# Releasing Shidou

Shidou auto-updates with [Sparkle](https://sparkle-project.org). Releases live in
a **Cloudflare R2** bucket served at **`https://releases.shidou.dev`**. New users
download a notarized **`.dmg`**; existing users get smaller in-app updates
(binary deltas when available) via Sparkle, which reads the appcast at
`https://releases.shidou.dev/appcast.xml`, verifies each build's EdDSA signature,
and installs it. One release command produces and publishes both.

Shidou has four **Delivery Channels** that ship independently
([ADR 0004](docs/adr/0004-independent-delivery-channels.md)): the **Desktop
Release** described here, the **iOS Release** through TestFlight
([docs/releasing-ios.md](docs/releasing-ios.md)), and the **Browser** and
**Website Deployments**, two Cloudflare Workers that deploy on every merge to
`master`. Desktop and iOS each have their own version and changelog. One
front door drives all of them:

```sh
bun run ship            # show every channel; ship the one that changed
bun run ship desktop    # or: ios, browser, website
bun run ship status     # what each channel last shipped, and what master holds beyond it
```

`bun run release` (this document) and `bun run ios-release` remain the
channel-specific commands underneath. See [Shipping](#shipping) for the pull
request labels and Change Notes every change needs first.

- Updater code: [`src/updater.rs`](src/updater.rs) — loads the embedded
  Sparkle.framework at runtime and starts `SPUUpdater` with Shidou's custom user
  driver. Available updates appear in the sidebar footer; download, signature
  verification, install, and relaunch remain owned by Sparkle. **Check for
  Updates…** lives in the app menu, and the **Automatic updates** toggle in
  Settings → General mirrors Sparkle's persisted setting.
- Feed URL + public key: [`resources/Info.plist`](resources/Info.plist)
  (`SUFeedURL`, `SUPublicEDKey`).
- Framework embedding + pinned Sparkle version:
  [`scripts/bundle.sh`](scripts/bundle.sh) (bump `sparkle_version` and
  `sparkle_sha256` together; the distribution is cached under
  `.shidou-cache/sparkle/`).
- Release automation: [`scripts/release.ts`](scripts/release.ts),
  [`scripts/appcast.ts`](scripts/appcast.ts),
  [`scripts/changelog.ts`](scripts/changelog.ts).
- GitHub Actions: [`.github/workflows/release.yml`](.github/workflows/release.yml)
  builds Linux (x86_64, arm64), Windows (x86_64, arm64), and macOS archives on
  a `desktop/v*` tag — or on a manual **Run workflow**, which takes the
  version from `Cargo.toml` — and opens a draft GitHub release;
  [`.github/workflows/sync-release.yml`](.github/workflows/sync-release.yml)
  copies published assets into the R2 bucket.
- Channel tooling: [`scripts/ship.ts`](scripts/ship.ts) (the front door),
  [`scripts/changes.ts`](scripts/changes.ts) (Change Notes),
  [`scripts/channels.ts`](scripts/channels.ts) (Delivery Records),
  [`scripts/pr-check.ts`](scripts/pr-check.ts) (the pull request gate).

---

## Shipping

### Pull request labels

Anything that can ship reaches `master` through a pull request labeled with
the apps it affects: `app:desktop`, `app:ios`, `app:browser`, `app:website`,
or `no-release` when nothing user-visible ships (docs, CI, tests, refactors;
it may sit beside `app:*` labels). The
[Pull request labels and notes](.github/workflows/pr-check.yml) workflow
enforces this on every pull request:

- A change under a path that belongs to one app must carry that app's label:
  `src/`, `resources/`, `crates/shidou-client/`, `crates/shidou-daemon/` →
  `app:desktop`; `apps/ios/` → `app:ios`; `apps/web/` → `app:browser`;
  `website/` → `app:website`. Extra labels are always allowed.
- Shared code (`crates/shidou-core/`, `crates/shidou-protocol/`,
  `packages/shidou-client/`, `bun.lock`) only warns: the author knows which
  Clients it reaches.
- A change to `PROTOCOL_VERSION` needs `app:desktop`, `app:ios`,
  `app:browser`, and `protocol:breaking`, and the three Clients then ship
  together (Desktop first, with `--force-protocol`). Prefer a compatible
  protocol change.

Create the labels once with `./scripts/setup-labels.sh`.

### Change Notes

Every user-visible change adds one file under [`.changes/`](.changes/README.md)
with wording for each labeled Client:

```markdown
---
desktop: Choose Claude Fable 5.1 from the model picker
ios: same-as desktop
browser: Pick Claude Fable 5.1 in the model menu
---
```

Keys are `desktop`, `ios`, and `browser` (`app:website` PRs need no note);
`same-as <app>` reuses another app's wording; a body below the frontmatter is
optional and never published. Write for the product users receive, not the
development history: when a feature is still unreleased, edit its existing
note instead of adding another. CI fails a PR whose `app:*` label has no
matching wording, and a `no-release` PR that adds a note.

Releases fold the pending notes into the channel's changelog
(`CHANGELOG.md` for Desktop, `CHANGELOG-ios.md` for iOS) and add the channel
to the note's `shipped:` list; the Browser deployment marks its notes from
CI. A note is deleted once every Client it names has shipped it.
`bun scripts/changes.ts check` validates the directory.

### Delivery Records

Each channel records the exact commit it last delivered, and `bun run ship
status` compares `master` with it:

| Channel | Record | Written when |
| --- | --- | --- |
| Desktop Release | `desktop/v<version>` tag | the GitHub release is published (created at the built commit) |
| iOS Release | `ios/v<marketing-version>-build.<build-number>` tag | App Store Connect reports the build VALID and in internal testing |
| Browser Deployment | GitHub deployment, environment `browser` | deploy-workers marks the deployment `success` |
| Website Deployment | GitHub deployment, environment `website` | deploy-workers marks the deployment `success` |

A draft release, a local build, or an upload still processing is not a
record. Plain `v*` tags end at `v0.2.14`.

### `bun run ship`

With no channel, it shows every channel and ships the one with unshipped
code or notes; with several it lists them and asks (in CI it fails and wants
`bun run ship <channel>`); with none it exits. For Desktop and iOS, one run:

1. refuses a dirty tree or a `master` that is not at `origin/master`, and
   refuses a Client whose `PROTOCOL_VERSION` differs from the last Desktop
   Release unless `--force-protocol`;
2. prints the plan — channel, version, commit, pending notes — and stops
   there with `--dry-run`;
3. creates `release/<channel>-<version>`, writes the changelog section from
   the pending notes (refusing an empty one without `--allow-empty-notes`),
   marks the notes shipped, opens the release pull request, waits for checks,
   and squash-merges it. Desktop bumps its version. iOS keeps its marketing
   version for routine TestFlight builds; `--app-store-version <x.y.z>` makes
   the explicit marketing-version change for an App Store update;
4. publishes: Desktop dispatches the Release workflow on `master`, publishes
   the draft, and waits for the R2 sync; iOS runs the ShidouKit tests, chooses
   the next build across all ASC uploads, waits for internal testing, and
   pushes the build-specific `ios/v*` tag.

An interrupted run resumes from step 4 when `master` already carries the
release commit. `--force` rebuilds or redeploys shipped code; it never skips
the tree, test, note, or protocol checks. Browser and website report status,
and `--force` dispatches deploy-workers for that Worker.

One explicit "ship Desktop" or "ship iOS" request authorizes the whole run;
the plan is printed first and there is no second prompt.

---

## One-time setup

**Run `./scripts/setup-release.sh`** — an interactive wizard that walks
through everything below: Sparkle keys, the Developer ID certificate,
notarization credentials, the R2 bucket and token, and the optional analytics
and Windows-signing values. It writes `.env` and the GitHub Actions secrets as
it goes. The sections below describe the same steps for doing it by hand.

The release runs on [Bun](https://bun.sh) and needs
[`create-dmg`](https://github.com/create-dmg/create-dmg) and
[rclone](https://rclone.org) (`brew install bun create-dmg rclone`).

### 1. Sparkle signing keys

Updates are signed with an ed25519 key; the private half stays in the login
keychain and the public half ships in Info.plist as `SUPublicEDKey`.

Shidou's public key is already recorded as `SUPublicEDKey` in
`resources/Info.plist`. Do not replace it for an existing release channel:
installed copies trust that key, so rotating it would strand them. For a new
fork or release channel, run the release wizard (`scripts/setup-release.sh`),
which generates a keypair, writes the new public key into Info.plist, and
uploads the private key as the `SPARKLE_PRIVATE_KEY` GitHub secret.

To do it by hand instead, use the Sparkle tools (they land in
`.shidou-cache/sparkle/<version>/bin` after any build, or download the
release from
[sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle/releases)):

```sh
./bin/generate_keys                               # generates into the keychain
./bin/generate_keys -p                            # prints the public key — put
                                                  # it in SUPublicEDKey
./bin/generate_keys -x sparkle_private_key.txt    # export for backup + CI
```

> ⚠️ Lose the private key and existing installs can never update again. Keep
> a password-manager backup current.

### 2. Developer ID signing + notarization

Copy `.env.example` to `.env` and replace the signing and analytics
placeholders. Bun loads these values before Cargo compiles the release, so the
analytics endpoint and website ID are embedded in the executable. The script
notarizes with the `NOTARY` keychain profile by default. On a fresh machine:

```sh
cp .env.example .env
xcrun notarytool store-credentials NOTARY \
  --apple-id you@example.com --team-id YOUR_APPLE_TEAM_ID
```

Override the environment with `--signing-identity`, or change the notary
profile with `--notary-profile` / `SHIDOU_NOTARY_PROFILE`.

### 3. Cloudflare R2 bucket + domain

The Shidou release channel already uses the resources below. Create and
configure equivalents when setting up a new fork or replacement channel:

1. Create the bucket **`shidou-releases`** (Cloudflare dashboard → R2 → Create
   bucket). The release script will not create it — a bucket-scoped API token
   can't.
2. Attach the custom domain **`releases.shidou.dev`** to the bucket (bucket →
   Settings → Custom Domains). This serves objects publicly at
   `https://releases.shidou.dev/<file>`.
3. Create an R2 API token that covers this bucket (R2 → Manage API Tokens →
   Object Read & Write) and configure an `r2` rclone remote with it
   (`~/.config/rclone/rclone.conf`, type S3, provider Cloudflare,
   `no_check_bucket = true`). `rclone lsf r2:shidou-releases
   --s3-no-check-bucket` should list the (empty) bucket without error.

The release wizard (`scripts/setup-release.sh`) walks through all of this and
sets the matching GitHub secrets for CI.

---

## Cutting a release

`bun run ship desktop` does all of the below from a clean `master`. The steps
are listed for understanding it and for doing a release by hand.

1. **Bump the version:**
   ```sh
   bun run bump --app desktop patch   # or: minor, major, or an explicit 0.3.0
   ```
   `version` in `Cargo.toml` is the Desktop version (iOS has its own in
   `apps/ios/project.yml`).
   `CFBundleShortVersionString` is the version, and `CFBundleVersion` is
   derived from it (`major*1e6 + minor*1e3 + patch`, so `0.2.0` → `2000`),
   which keeps Sparkle's build-number comparison monotonic without a manual
   counter. Prerelease versions (`-beta.1`) are refused for publishing — the
   appcast serves one stable channel.

   Two generated files embed that version, so the bump is not just a manifest
   edit: `Cargo.lock`'s workspace entry, and the Rust license report
   (`licenses/THIRD_PARTY_RUST_LICENSES.html`, which lists every workspace
   crate as `shidou <version>`). `bun run bump` rewrites the manifest, runs
   `cargo update --workspace`, and regenerates every license report, so all
   three land in one commit. Editing `Cargo.toml` by hand instead leaves the
   report describing the previous release, and CI's `licenses:check` fails on
   the next push. It needs `cargo-about` (`cargo install cargo-about
   --locked`); `bun run release` refuses to build a version the report does not
   list.
2. **Write the release notes** — add a `## [<version>]` section at the top of
   [`CHANGELOG.md`](CHANGELOG.md) from the pending Change Notes
   (`bun scripts/changes.ts pending desktop`), then mark them shipped
   (`bun scripts/changes.ts ship desktop`). Commit through a pull request
   labeled `no-release`.
3. **Run it:**
   ```sh
   bun run release
   ```

The script checks R2 up front (bucket reachable, version not already
published), builds and signs the app via `scripts/bundle.sh release`, verifies
the bundled JS REPL and computer-use helper, builds the styled DMG, notarizes
and staples DMG + app, zips the app for Sparkle, pulls the recent archives
from R2 so `generate_appcast` can build binary deltas, attaches the changelog
section as release notes, regenerates the signed `appcast.xml`, and uploads
everything with immutable cache headers (the appcast itself stays
`max-age=300`). When it finishes:

- **Download link**: `https://releases.shidou.dev/Shidou-<version>.dmg`
- **In-app updates**: served from the same origin via the appcast.

Test by keeping an older build around, launching it, and choosing
**Check for Updates…**.

### GitHub draft release + R2 sync

The Release workflow runs two ways:

- **Actions → Release → Run workflow** (what `bun run ship desktop` does) —
  no tag needed. The run releases whatever `Cargo.toml` says and drafts it as
  `desktop/v<version>`; that tag is created at the built commit when the
  draft is published, and it is the Desktop Delivery Record.
- **Push a `desktop/v*` tag** — the tag must match the `version` in
  `Cargo.toml`, or the run fails before anything builds.

macOS CI runs `bun run release --local`, which signs, notarizes, and writes the
same artifacts as a local release:

- `Shidou-<version>.dmg`
- `Shidou-<version>.zip`
- `appcast.xml` (Sparkle-signed)
- `shidou-<version>-source.tar.gz` (matching source and build scripts)

Linux CI adds:

- `shidou-<version>-x86_64-unknown-linux-gnu.tar.gz`
- `shidou-<version>-aarch64-unknown-linux-gnu.tar.gz`
- `latest-linux.txt` — the version `install.sh` resolves "latest" to

Windows CI adds:

- `Shidou-<version>-x86_64-Setup.exe`
- `Shidou-<version>-aarch64-Setup.exe`
- `shidou-<version>-x86_64-pc-windows-msvc.zip` (portable)
- `shidou-<version>-aarch64-pc-windows-msvc.zip` (portable)
- `appcast-windows-x86_64.xml`, `appcast-windows-aarch64.xml`
- `latest-windows.txt` — the version the download page resolves "latest" to

[`scripts/bundle-windows.ts`](scripts/bundle-windows.ts) builds both, driving
[`resources/windows/shidou.iss`](resources/windows/shidou.iss) through Inno Setup's
`ISCC`. The installer is **per-user** (`PrivilegesRequired=lowest`,
`%LOCALAPPDATA%\Programs\Shidou`) — no elevation, which is exactly what lets the
updater re-run it silently. The script signs the two executables and the
installer with Authenticode when `WINDOWS_CERTIFICATE` and
`WINDOWS_CERTIFICATE_PASSWORD` are set, and packages them unsigned otherwise,
so a fork without a certificate can still cut a release at the cost of a
SmartScreen warning.

**Never change `AppId` in `shidou.iss`.** It is how Windows recognizes an
existing install; a new one turns every update into a second copy in
Add/Remove Programs.

#### The Windows update feed

Windows has no Sparkle, so [`src/updater.rs`](src/updater.rs) runs the same
contract itself: fetch the appcast, compare versions, download, verify the
EdDSA signature, and hand the installer to Inno Setup with `/SILENT`. The
installer closes Shidou, replaces it, and starts it again.

- **One feed per architecture.** A Sparkle appcast cannot say which binary an
  item is for, and the client picks its feed at compile time.
- **Same key as macOS.** `build.rs` reads `SUPublicEDKey` out of
  `resources/Info.plist` and compiles it in, so the two platforms cannot drift
  onto different keys.
- [`scripts/appcast-windows.ts`](scripts/appcast-windows.ts) signs the feeds in
  the draft-release job — the only one holding both installers. There is no
  `sign_update` on Linux, so it signs with Node's Ed25519 over the same
  `SPARKLE_PRIVATE_KEY`, and refuses to run when the key does not derive
  `SUPublicEDKey` (signing with the wrong key ships a feed the app rejects).
- The step pulls the live feeds down first and merges, so previously published
  releases keep their entries.

Both Linux jobs run on **Ubuntu 22.04**, and that choice is load-bearing: the
binaries link against the build machine's glibc, so the runner sets the oldest
distribution Shidou can start on (2.35 — Ubuntu 22.04, Debian 12, Fedora 36).
Moving those jobs to a newer runner silently drops support for everything
older.

The workflow opens (or updates) a **draft** GitHub release with those files and
the matching `CHANGELOG.md` section. Publishing the GitHub release syncs the
assets — including the signed `appcast.xml` — to R2.

`appcast.xml`, `latest-linux.txt`, and `latest-windows.txt` are the bucket's
mutable pointers and upload with a short cache lifetime; everything else is
versioned and cached forever. Linux users install from that bucket via
[`website/public/install.sh`](website/public/install.sh), served at
`https://shidou.dev/install.sh` — see [docs/linux.md](docs/linux.md).

Every release archive carries `LICENSE`, `THIRD_PARTY_NOTICES.md`, and the
generated dependency-license report. The matching versioned source archive is
published beside the binaries in GitHub Releases and R2.

Publishing that GitHub release (or running **Sync release** from Actions)
uploads the assets to the `shidou-releases` R2 bucket. Configure these repository
secrets first:

| Secret | Purpose |
| --- | --- |
| `SHIDOU_ANALYTICS_ENDPOINT` | embedded in the macOS CI build |
| `SHIDOU_ANALYTICS_WEBSITE_ID` | embedded in the macOS CI build |
| `SHIDOU_SIGNING_IDENTITY` | Developer ID identity selector |
| `APPLE_CERTIFICATE` | base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | password for that `.p12` |
| `APPLE_ID` | Apple ID used by `notarytool` |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Developer Team ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for `generate_appcast` |
| `WINDOWS_CERTIFICATE` | optional; base64-encoded Authenticode `.pfx` |
| `WINDOWS_CERTIFICATE_PASSWORD` | optional; password for that `.pfx` |
| `R2_ACCOUNT_ID` | Cloudflare account id for the R2 API |
| `R2_ACCESS_KEY_ID` | R2 Object Read & Write token |
| `R2_SECRET_ACCESS_KEY` | matching secret |
| `R2_BUCKET` | optional; defaults to `shidou-releases` |

### Options

| Flag / Env | Default | Purpose |
| --- | --- | --- |
| `--local` | — | build, notarize, and write the DMG + zip without publishing |
| `--force` | — | re-publish a version that already exists in R2 |
| `--adhoc`, `--skip-notarize` | — | local test builds (imply `--local`) |
| `--skip-build` | — | reuse existing release binaries |
| `--build-number <n>` / `SHIDOU_BUILD_NUMBER` | derived | `CFBundleVersion` override |
| `SHIDOU_R2_REMOTE` | `r2` | rclone remote name |
| `SHIDOU_R2_BUCKET` | `shidou-releases` | R2 bucket |
| `SHIDOU_DOWNLOAD_URL_PREFIX` | `https://releases.shidou.dev/` | base URL in the appcast |
| `SHIDOU_HISTORY_COUNT` | `15` | recent archives pulled for delta generation |
| `SHIDOU_NO_HISTORY=1` | — | skip pulling old archives (full updates only) |
| `SPARKLE_BIN` | the `.shidou-cache` copy | Sparkle tools directory |

---

## Notes

- **Two artifacts per release:** the notarized `.dmg` (what people download)
  and a `.zip` (what Sparkle installs, plus `.delta` files against recent
  builds). Only the zip family appears in the appcast; point download buttons
  at the DMG.
- **Debug builds never update themselves.** `Updater::init` returns `None`
  under `debug_assertions`, so the dev watcher's app can't offer to replace
  itself with a production Shidou. Set `SHIDOU_FORCE_UPDATER=1` to exercise the
  real Sparkle flow from a debug bundle anyway. A bare `cargo run` binary has
  no embedded framework and also degrades to no updater. For UI-only testing,
  start the watcher with `SHIDOU_PREVIEW_UPDATE=1`; the sidebar immediately
  shows an available update and clicking it changes to the spinner without
  installing anything. The preview flag fakes only that sidebar result;
  **Check for Updates…** still uses the embedded Sparkle framework and its
  real standard window.
- **Automatic and explicit checks have separate presentation.** Scheduled
  checks stay silent until the sidebar update button appears. Choosing
  **Check for Updates…** promotes an existing silent result into Sparkle's
  standard updater window, or shows its checking progress while an automatic
  check finishes. With no automatic session active, it starts Sparkle's
  standard user-initiated check directly.
- **First-run consent:** Sparkle shows its one-time "check automatically?"
  prompt on the second launch. The Settings → General toggle reads and writes
  the same persisted value.
- **Shidou isn't sandboxed**, so Sparkle's XPC services are unnecessary;
  `bundle.sh` strips them (plus headers/modules) from the embedded framework
  and re-signs the rest with the app's identity — hardened-runtime library
  validation requires the identities to match.
- **Old archives stay in R2** so far-behind users can still be served; only
  the recent history is staged locally under `dist/updates/` (git-ignored).
- **Platform artifacts:** keep the bucket layout flat and platform-tagged by
  artifact name/extension — today's macOS names
  (`Shidou-<v>.dmg`, `Shidou-<v>.zip`, `appcast.xml`) must keep their URLs.
  Linux CI releases produce `shidou-<v>-<target>.tar.gz` with
  `scripts/bundle-linux.sh`, Windows CI produces `shidou-<v>-<target>.zip` with
  `scripts/bundle-windows.ts`, and both land in GitHub Releases, then R2 via
  the sync workflow. Windows also ships `Shidou-<v>-<arch>-Setup.exe` and updates
  itself from `appcast-windows-<arch>.xml`. Automatic Linux updates are still
  not wired — re-running `install.sh` is the upgrade path, and
  `latest-linux.txt` is how a client learns what "latest" means.
  `src/updater.rs` is the per-platform seam, and everything
  mac-specific in the existing release pipeline lives behind the Darwin guard
  in `scripts/release.ts` plus `scripts/bundle.sh`.

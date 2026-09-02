---
name: ios-release
description: >
  Build, verify, and upload the Shidou iOS app to TestFlight. Use when the
  user asks to push a TestFlight build, cut an iOS release, ship the iOS app,
  or upload to App Store Connect — including after landing iOS changes.
---

# iOS TestFlight release

The canonical process lives in `docs/releasing-ios.md`; this skill is the
working recipe on top of it — the flags, the gotchas, and the poll loop.

## 0. Prefer the front door

```sh
bun run ship ios            # add --dry-run to see the plan first
```

From a clean `master` it keeps the TestFlight marketing version, resolves the
next globally increasing build number, writes `CHANGELOG-ios.md` from the
pending Change Notes, lands the release pull request, runs the ShidouKit
tests, uploads and waits, and pushes an
`ios/v<marketing-version>-build.<build-number>` Delivery Record. Pass
`--app-store-version <x.y.z>` only for an App Store update. One explicit "ship iOS"
request authorizes the whole run. If the merge landed but publishing
failed, run it again; it resumes from the upload. Use the steps below only
when something in that pipeline needs doing by hand.

The change being shipped must already be on `master` through a pull request
labeled `app:ios` with a Change Note carrying `ios:` wording (or
`no-release`). The archive is built from the working tree, so `git status`
must be clean; never release uncommitted state.

## 1. Verify before anything leaves the machine

- Unit tests: `cd apps/ios/Packages/ShidouKit && swift test` — all green.
- The archive script re-checks the App Store Connect killers itself (version
  stamps, export compliance, ATS exemption), so a plain build is not a
  separate step.

If the changes touch behavior (not just strings), also drive the UI suite
against a live fixture daemon:

1. `cargo build -p shidou-demo`, then run
   `./target/debug/shidou-demo --bind 127.0.0.1:8787` (port 8787 already
   listening from an earlier session is fine to reuse).
2. Boot a simulator, `xcodebuild ... build-for-testing`, then
   `xcodebuild ... test-without-building` with the Shidou scheme — 12 tests,
   1 skip expected (the iPad inspector test on an iPhone simulator).

To visually verify a screen the tests cannot tap to, start one test in the
background and capture `xcrun simctl io <udid> screenshot` on a loop while
it runs.

## 2. Upload

```sh
bun run ios-release --upload --next-build-number --wait --profile "Shidou TestFlight 2026-08-28"
```

- **Build number**: `--next-build-number` asks ASC for the highest build
  across every marketing version and goes one higher. Routine TestFlight
  uploads keep `MARKETING_VERSION`; only the build changes. Pass an explicit
  `--build-number <n>` only when ASC is unreachable.
- **Profile**: the named profile is mandatory (`--profile`, or
  `SHIDOU_IOS_PROFILE` in `.env` so `bun run ship ios` picks it up). Cloud
  signing is blocked at the account level, and Apple does not serve profile content to API keys, so
  the profile was created via the API and installed locally (2027 expiry). If
  the upload fails with a *cloud signing permission error*, the profile name
  is the missing flag — it is not a certificate problem.
- **Credentials**: `.env` carries the ASC key id/issuer and
  `SHIDOU_ASC_API_KEY_PATH`; keep the `.p8` at
  `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`. The release script points
  altool there with `API_PRIVATE_KEYS_DIR` and never copies credentials into
  the repository. If a key is found in the checkout, move it to that user-level
  directory before continuing. Never print key contents.

## 3. Poll until it is live

Upload ≠ available, and the iOS Release counts as shipped only once testers
can install it. `--wait` polls the ASC API until `processingState == "VALID"`
and `buildBetaDetail` reports `internalBuildState: IN_BETA_TESTING` (30 s
interval; the first checks often come back empty). Without it, poll the same
two endpoints yourself (`scripts/asc.ts` → `AscApi.listBuilds`,
`buildBetaState`). Only then push the record:

```sh
git tag -a ios/v<version>-build.<build> <commit> -m "iOS <version> build <build>" && git push origin ios/v<version>-build.<build>
```

The internal testing group receives every build automatically — manual
assignment is rejected by design (422). There is no dashboard step.

## 4. Report

Tell the user: build number, VALID status, and that it appears in TestFlight
shortly (their device: install from the TestFlight app). External testers and
Beta App Review are a separate, never-automatic step.

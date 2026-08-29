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

## 0. Commit first

The archive is built from the working tree, so `git status` must be clean
before uploading. Commit and push the changes being shipped; never release
uncommitted state.

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
bun run ios-release --upload --build-number <n> --profile "Shidou TestFlight 2026-08-28"
```

- **Build number**: the default (derived from Cargo.toml) is correct only for
  the *first* upload of a marketing version. Re-uploading the same version
  needs an explicit increasing number. Query the highest used one first via
  the ASC API (`scripts/asc.ts` → `AscApi`, app record `6806198658`,
  `GET /v1/builds?filter[app]=…&sort=-uploadedDate`) and pass `max + 1`.
- **Profile**: the named profile is mandatory. Cloud signing is blocked at
  the account level, and Apple does not serve profile content to API keys, so
  the profile was created via the API and installed locally (2027 expiry). If
  the upload fails with a *cloud signing permission error*, the profile name
  is the missing flag — it is not a certificate problem.
- **Credentials**: `.env` carries the ASC key id/issuer; the `.p8` lives in
  `private_keys/`. If a key file is ever found sitting at the repo root, move
  it into `private_keys/` — it is one careless `git add` away from being
  committed. Never print key contents.

## 3. Poll until it is live

Upload ≠ available. Poll with the ASC API until
`processingState == "VALID"` (`GET /v1/builds?filter[app]=…&filter[version]=<n>`,
30 s interval; first check often comes back empty). Then confirm
`GET /v1/builds/<id>/buildBetaDetail` reports `internalBuildState:
IN_BETA_TESTING`.

The internal testing group receives every build automatically — manual
assignment is rejected by design (422). There is no dashboard step.

## 4. Report

Tell the user: build number, VALID status, and that it appears in TestFlight
shortly (their device: install from the TestFlight app). External testers and
Beta App Review are a separate, never-automatic step.

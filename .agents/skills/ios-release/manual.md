# Manual iOS release recovery

Use only when `bun run ship ios` cannot complete the pipeline. The canonical
release documentation is [docs/releasing-ios.md](../../../docs/releasing-ios.md).
Run commands from the repo root.

## Verification

Ship only committed changes landed on `master` through a PR with the appropriate
labels and Change Note. The archive uses the working tree, which must be clean.

Run the ShidouKit unit tests with `cd apps/ios/Packages/ShidouKit && swift test`.
The archive script verifies version stamps, export compliance, and the ATS
exemption; a separate plain build is unnecessary.

For behavior changes, run the affected UI suite against a live fixture daemon:

- Build `cargo build -p shidou-demo` and run
  `./target/debug/shidou-demo --bind 127.0.0.1:8787`. Reuse an existing fixture
  daemon on that port after confirming its identity.
- Boot a simulator and use `xcodebuild build-for-testing`, then
  `xcodebuild test-without-building` with the Shidou scheme and that destination.
  Determine expected skips from the current tests rather than a fixed count.
- Capture screenshots only when visual testing was requested.

## Upload and signing

```sh
bun run ios-release --upload --next-build-number --wait --profile "Shidou TestFlight 2026-08-28"
```

`--next-build-number` queries ASC for the highest build across all marketing
versions and increments it. Routine TestFlight uploads keep `MARKETING_VERSION`.
Use an explicit `--build-number` only when ASC is unreachable.

The named profile is required via `--profile` or `SHIDOU_IOS_PROFILE` in `.env`.
Cloud signing is blocked at the account level; Apple does not serve profile
content to API keys. The locally installed profile expires in 2027. A cloud
signing permission error usually means the profile flag is missing, not that
its certificate needs replacing.

`.env` holds the ASC key id, issuer, and `SHIDOU_ASC_API_KEY_PATH`. Keep the `.p8`
at `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`; the script sets
`API_PRIVATE_KEYS_DIR` without copying credentials into the checkout. Never
print key contents. If credentials are in the checkout, stop and ask permission
to relocate them before continuing.

## Completion

`--wait` polls every 30 seconds until ASC reports `processingState == "VALID"`
and `buildBetaDetail.internalBuildState == "IN_BETA_TESTING"`. Initial queries
may be empty. Without `--wait`, use `AscApi.listBuilds` and `buildBetaState` in
`scripts/asc.ts` to check those same states.

Only after both states are confirmed, create and push the Delivery Record
for the shipped commit:

```sh
git tag -a ios/v<version>-build.<build> <commit> -m "iOS <version> build <build>"
git push origin ios/v<version>-build.<build>
```

The internal testing group receives builds automatically. Manual assignment is
rejected with 422; no dashboard action is needed. External testing and Beta App
Review require a separate request.

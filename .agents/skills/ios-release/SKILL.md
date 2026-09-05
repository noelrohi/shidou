---
name: ios-release
description: Ship Shidou to TestFlight when the user explicitly requests an iOS release or upload.
---

# iOS TestFlight release

Read [docs/releasing-ios.md](../../../docs/releasing-ios.md) for release
requirements, then run from a clean `master` with the changes already landed:

```sh
bun run ship ios
```

One explicit iOS shipping request authorizes the whole run. The command handles
release notes, the release PR, tests, upload, processing wait, and the Delivery
Record. `--dry-run` previews the plan. Use `--app-store-version <x.y.z>` only for
an App Store marketing-version update.

For behavior changes, run the affected simulator UI suite against the fixture
daemon before shipping; see [manual verification](manual.md#verification).

The local signing profile must be set through `SHIDOU_IOS_PROFILE`; see
[manual.md](manual.md) for signing setup or a failed pipeline needing manual
verification, upload, or polling. If the release PR merged but publishing
failed, rerun `bun run ship ios` to resume the upload.

Done means ASC reports `VALID` and `IN_BETA_TESTING`, and the Delivery Record
has been pushed. Report the version, build number, and verified status, or the
blocker if incomplete. External testers and Beta App Review are separate and
never automatic.

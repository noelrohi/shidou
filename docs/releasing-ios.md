# Releasing Shidou for iOS

How a build gets from `master` to a phone through TestFlight. The desktop
release process lives in [RELEASING.md](RELEASING.md); this is the iOS
counterpart. Cargo.toml's version is the source of truth for both.

## The one command

```sh
bun run ios-release                 # archive + verify
bun run ios-release --export        # + signed IPA
bun run ios-release --upload        # + App Store Connect upload
```

`scripts/ios-release.ts` regenerates the Xcode project (xcodegen), archives
the Shidou scheme against **Release** for a generic iOS device, stamps
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` from Cargo.toml, then
verifies the archive before anything leaves the machine:

- the marketing version and build number actually took,
- `ITSAppUsesNonExemptEncryption = NO` survived into the built Info.plist
  (clears export compliance without a per-upload prompt),
- `NSAppTransportSecurity.NSAllowsLocalNetworking = YES` survived (the
  cleartext `ws://` exemption, [issue #5](https://github.com/noelrohi/shidou/issues/5)),
- the compiled app carries its asset catalogue and the icon source exists.

App Store Connect rejects an upload over any of these and only says so after
the upload, so the script checks first.

### Build numbers

ASC refuses a build number it has already seen for the same marketing
version. The default derives from the Cargo version — `major*1_000_000 +
minor*1_000 + patch`, the same scheme as the desktop's `CFBundleVersion`
([`scripts/version.ts`](scripts/version.ts)) — which is right for the **first
upload of a version**. Re-uploading the same marketing version needs an
explicit, increasing override:

```sh
bun run ios-release --upload --build-number 2010
```

(`bun run bump` also writes the derived pair into
[`apps/ios/project.yml`](apps/ios/project.yml), so a manual Xcode archive
carries correct values without the script.)

### Credentials

`--upload` needs an App Store Connect API key (`--api-key-id` +
`--api-issuer`, plus `--api-key-path` unless `AuthKey_<id>.p8` already sits
in `./private_keys/`, `~/private_keys/`, `~/.private_keys/`, or
`~/.appstoreconnect/private_keys/`). With a key, xcodebuild can also create
the Apple Distribution certificate it needs for the export; without one, an
existing distribution certificate in the keychain is enough.

## What only the App Store Connect dashboard can do

The script cannot do any of this; the first time through, do it in order:

1. **Create the app record** — bundle id `dev.shidou.ios`, team
   `2Z79866758`, name *Shidou*, primary language. The bundle id must be
   registered on the team (Xcode's automatic signing does this on the first
   archive).
2. **Upload the build** — `bun run ios-release --upload`, or drag the IPA
   into Xcode Organizer / Transporter. Wait out processing (a few minutes;
   an export-compliance prompt here means the Info.plist key was lost —
   treat that as a bug in `apps/ios/project.yml`).
3. **Internal testing** — create an internal tester group under
   TestFlight → Internal Testing and add yourself. Internal testers must
   hold an App Store Connect role on the team; internal testing needs **no
   Beta App Review**, which is why this lands before the device pass and
   before the external build that does need review
   ([#17](https://github.com/noelrohi/shidou/issues/17)).
4. **Install** — accept the TestFlight invite on the phone, install,
   launch, and check it reaches the pairing screen.

## The manual Xcode route

If you would rather not use the script: open `apps/ios/Shidou.xcodeproj`
(after `xcodegen generate`), set the **Any iOS Device** destination, and
**Product → Archive**. Confirm in the archive's Info.plist that
`ITSAppUsesNonExemptEncryption` and `NSAllowsLocalNetworking` are present —
they come from [`apps/ios/project.yml`](apps/ios/project.yml) and a stale
project generation is the usual way they go missing. **Distribute App →
TestFlight & App Store** uploads it. Bump the build number in the target's
build settings first if this marketing version was already uploaded.

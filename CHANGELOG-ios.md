# iOS Changelog

All notable changes to the Shidou iOS app. The iOS Client has its own release
line (see `docs/adr/0004-independent-delivery-channels.md`): its version lives
in `apps/ios/project.yml`, and `bun run ship ios` adds a `## [<version>]`
section here from the pending Change Notes under `.changes/` when it cuts a
release. Desktop notes live in `CHANGELOG.md`.

Format follows [Keep a Changelog](https://keepachangelog.com). Releases
before 0.2.14 shared the desktop version and its changelog.

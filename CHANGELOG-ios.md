# iOS Changelog

All notable changes to the Shidou iOS app. The iOS Client has its own release
line (see `docs/adr/0004-independent-delivery-channels.md`): its App Store
marketing version lives in `apps/ios/project.yml`, and `bun run ship ios` adds
a `## [<version>-build.<number>]` section here from pending Change Notes for
each TestFlight delivery. Desktop notes live in `CHANGELOG.md`.

Format follows [Keep a Changelog](https://keepachangelog.com). Releases
before 0.2.14 shared the desktop version and its changelog.

## [0.2.13-build.2029]

- Nest Child Tasks beneath their parent in the task list
- Make “Don't work in a project” reliably switch new tasks to a scratch workspace

## [0.2.13-build.2028]

- Maintenance release with no user-visible changes

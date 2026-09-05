# Shidou development guidance

## Development runtime

- Assume `bun ./scripts/dev.ts` owns `Shidou Debug.app` and automatically
  rebuilds, signs, and relaunches it after source changes. Wait for its successful
  rebuild before validating desktop changes.
- Do not run `scripts/bundle.sh debug`, start a second watcher, or manually
  quit/relaunch the debug app. Quitting also stops the watcher. Start or recover
  the watcher only after confirming it is unavailable.
- Run visual tests only when requested. Validate requested desktop UI tests in
  the freshly rebuilt, signed app against the exact interaction, not just a
  successful Rust build. Report any validation that remains undone.

## UI changes

- Performance and accessibility are product requirements. Keep heavy work and
  blocking I/O off the UI thread, and per-frame work proportional to visible
  content.
- For GPUI rendering, row measurement, or streaming changes, read
  [docs/performance.md](docs/performance.md). This includes the event pump,
  `src/ui/motion.rs`, veils, overlay scrollbars, and pane caching.
- For desktop controls, focus, styling, or motion, read
  [docs/agents/desktop-ui.md](docs/agents/desktop-ui.md).
- For ambiguous coding-agent workflow or transcript design decisions, consult
  current [T3 Code](https://github.com/pingdotgg/t3code) source. For GPUI
  implementation needing native precedent, consult
  [Zed](https://github.com/zed-industries/zed) at the GPUI revision pinned in
  `Cargo.toml`, not `gpui-component`. Skip reference research for localized fixes
  or clearly specified changes unless the user asks for comparison.
- Keep native macOS conventions. Explicit user screenshots and feedback take
  precedence over reference designs or existing treatments.
- For provider-native citations, reasoning, and tool events, verify the real
  payload and preserve its ordering. Never display private provider control
  markers in the transcript.

## Shipping

- Delivery Channels ship independently: Desktop Release, iOS Release, Browser
  Deployment, Website Deployment. Name the channel; do not call Workers a
  "release" or use "client" for the browser alone.
- Every PR needs `app:desktop`, `app:ios`, `app:browser`, `app:website`, or
  `no-release`, covering every app changed. User-visible changes need a Change
  Note in `.changes/` with wording for each labeled Client. Read
  [RELEASING.md](RELEASING.md) when preparing a PR or shipping.
- Ship with `bun run ship <channel>`. For an unspecified channel, run
  `bun run ship status`; proceed only if exactly one channel has unshipped work,
  otherwise show the channels and ask. Desktop and iOS require an explicit
  shipping request, which authorizes the whole run.
- `ship` generates versions and changelogs from notes. Do not bump versions or
  edit `CHANGELOG.md` / `CHANGELOG-ios.md` by hand for a release.

## Task-specific docs

- GitHub issue work: [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).
  Issues live on `noelrohi/shidou`; use `gh`.
- Issue triage: [docs/agents/triage-labels.md](docs/agents/triage-labels.md).
- Domain terminology or architecture decisions:
  [CONTEXT.md](CONTEXT.md), relevant [ADRs](docs/adr/), and
  [docs/agents/domain.md](docs/agents/domain.md).

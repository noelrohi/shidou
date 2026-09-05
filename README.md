# Shidou

Shidou is a native workspace for coding-agent tasks, based on
[Waku](https://github.com/egoist/waku). Use the Desktop Client on macOS, Linux,
or Windows, or connect to its daemon from the Browser Client or the iOS Client
(distributed through TestFlight).

Shidou runs your installed agent CLIs. The daemon owns provider processes,
task history, workspaces, and attachments; each connected app shows and
controls that work.

## What you can do

- Run tasks with Claude Code, Codex CLI, Amp, OpenCode, Pi, Oh My Pi,
  DeepSeek Harness, Fx, Grok Build, Cursor CLI, or Kimi Code.
- Review changes, browse workspace files, and attach images from the Visuals
  gallery. Image generation is optional and runs through your agent's tools.
- Checkpoint Git workspaces at turn boundaries and rewind code and conversation
  with supported providers. Provider capabilities differ; see the
  [provider guide](docs/providers.md).
- Connect another Shidou app to your daemon to continue working remotely.
  Expose it only over a trusted network or encrypted transport; the daemon
  token grants full control.

The desktop also includes a terminal and, on macOS and Windows, an embedded
browser. Computer Use is macOS-only.

## Install

Download the Desktop Client from [shidou.dev](https://shidou.dev) or
[GitHub Releases](https://github.com/noelrohi/shidou/releases).
See the [Linux](docs/linux.md) and [Windows](docs/windows.md) guides for
installation, updates, and platform requirements. macOS uses Sparkle for
in-app updates; Windows verifies and runs a signed update installer; Linux
upgrades by rerunning the install script.

Install and authenticate at least one supported coding-agent CLI before
starting a task. Shidou uses that CLI's provider account and configuration.

## Develop

Requirements: Rust 1.96+, Bun, the platform's native build prerequisites,
and a supported agent CLI to test provider integrations.

```sh
bun install
bun run dev
```

The watcher rebuilds the desktop or hot-swaps its external debug daemon as
needed. Keep it running; do not start a second watcher or manually relaunch
the debug app. See [CONTRIBUTING.md](CONTRIBUTING.md) for platform setup and
checks.

Optional image-generation setup lives in [Visual assets](docs/visual-assets.md).
`ima2-gen` is not required to build or use Shidou.

## Architecture and docs

- [`crates/shidou-protocol`](crates/shidou-protocol): versioned wire contract.
- [`crates/shidou-core`](crates/shidou-core): daemon-owned provider runtimes,
  persistence, filesystem, and Git services.
- [`crates/shidou-daemon`](crates/shidou-daemon): standalone authenticated
  WebSocket daemon.
- [`crates/shidou-client`](crates/shidou-client): Rust transport and daemon
  supervision for the GPUI Desktop Client in `src/`.
- [`apps/web`](apps/web): React Browser Client.
- [`apps/ios`](apps/ios): SwiftUI iOS Client and shared Swift packages.

Run `bun run protocol:generate` after changing wire types and
`bun run protocol:check` to verify generated TypeScript bindings.

See [CONTEXT.md](CONTEXT.md) for terminology, [RELEASING.md](RELEASING.md) for
the four independent Delivery Channels, and [SECURITY.md](SECURITY.md) for
vulnerability reporting. The [privacy policy](https://shidou.dev/privacy)
describes desktop usage analytics and remote-client data handling.

## License

Shidou is a derivative of [Waku](https://github.com/egoist/waku) and remains licensed under the [GNU General Public License v3.0 only](LICENSE). Copyright © egoist and the Waku contributors; modifications copyright © 2026 Rohi, forked from Waku in August 2026. `ima2-gen` is a separate MIT-licensed runtime and is not vendored into this repository.

Bundled dependency, font, icon, and framework notices are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the generated reports
under `licenses/` and each web application's `public/` directory.

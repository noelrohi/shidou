# Pagesmith

Pagesmith is a fast, native coding-agent workspace for ecommerce development. It is based on [Waku](https://github.com/egoist/waku) and supports visual asset work with the local [`ima2`](https://github.com/lidge-jun/ima2-gen) runtime.

## Visual assets

Image generation starts in the main composer, like any other coding task. Ask the agent—or use a project skill you maintain—to run `ima2` inside the current workspace and save its output in a project folder.

The right panel's singleton **Visuals** surface is a lightweight workspace gallery:

1. Choose a workspace folder containing images.
2. Pick **Compact grid**, **Large grid**, or **Fit / contain**.
3. Preview and multi-select images.
4. Choose **Attach selected to composer** when the agent needs those files as context.

Visuals does not own prompts, briefs, generation settings, references, rounds, or generation progress. Refresh the gallery after the agent creates new files. Folder indexing and image reads run through daemon APIs, so the same workflow works with remote workspaces without interpreting daemon-host paths on the client.

Supported gallery formats are GIF, JPEG, PNG, SVG, and WebP.

## Setup

Requirements:

- Rust 1.96+
- Bun
- A supported coding-agent CLI
- `ima2-gen` configured for the provider you intend to use

```sh
npm install -g ima2-gen
ima2 setup
ima2 ping

bun install
bun run dev
```

Pagesmith does not install an image-generation skill. Keep the prompt or skill that invokes `ima2` in your own agent/project configuration.

## Architecture

The GPUI desktop and React browser client connect to the standalone daemon through the versioned protocol in `crates/waku-protocol`. Provider sessions live in `crates/waku-core`. Internal crate and protocol names retain `waku` for a small, maintainable downstream diff.

The daemon has no image-generation RPC: the coding agent runs `ima2` itself, and Visuals only indexes and attaches the image files it writes into the workspace. The gallery imports a folder in one `importPathAttachments` round trip.

Pagesmith uses Bun for dependency management. Run `bun run protocol:generate` after changing wire types and `bun run protocol:check` to verify generated bindings.

The upstream Waku update feed is intentionally disabled; configure a Pagesmith-owned feed and signing key before distributing releases.

## License

Pagesmith is a derivative of Waku and remains licensed under the [GNU General Public License v3.0 only](LICENSE). `ima2-gen` is a separate MIT-licensed runtime and is not vendored into this repository.

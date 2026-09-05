# Visual assets

The Desktop and Browser Clients' **Visuals** panel is a workspace image gallery.
It displays files; it does not generate images or manage prompts, generation
settings, references, or progress.

## Browse and attach images

1. Choose a workspace folder containing images.
2. Pick **Compact grid**, **Large grid**, or **Fit / contain**.
3. Preview and multi-select images.
4. Choose **Attach selected to composer** to give the agent those files as context.

Supported formats are GIF, JPEG, PNG, SVG, and WebP. Refresh the gallery after
an agent creates new files. Folder indexing and image reads run through the
daemon, so the gallery also works with remote workspaces.

## Optional image generation with ima2

Ask the coding agent in the main composer to run
[`ima2`](https://github.com/lidge-jun/ima2-gen) in the current workspace and
save its output in a project folder. You can also maintain a project skill
for that workflow.

Install and configure the runtime on the machine where the agent runs:

```sh
bun add --global ima2-gen
ima2 setup
ima2 ping
```

Shidou does not install an image-generation skill or expose an image-generation
RPC. Keep the prompt or skill that invokes `ima2` in your own agent or project
configuration. The agent generates the files; Visuals indexes them and imports
selected images through `importPathAttachments` for attachment to a task.

`ima2-gen` is separate from Shidou and is not required to build the app or use
the gallery with existing images.

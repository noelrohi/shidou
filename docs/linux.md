# Shidou on Linux

## Install

```sh
curl -fsSL https://shidou.dev/install.sh | sh
```

The script needs no root. It unpacks the release tarball into
`~/.local/shidou.app` and installs the desktop entry into
`~/.local/share/applications`, so **Shidou appears in your applications menu** —
you can also launch it from a terminal via `shidou` command. Run the script again to
upgrade; it replaces the previous install rather than merging into it.

Shidou expects:

- **glibc 2.35 or newer** — Ubuntu 22.04, Debian 12, Fedora 36, and anything
  more recent. Releases are built on Ubuntu 22.04, so older distributions must
  build from source.
- **A working Vulkan or OpenGL driver.** Shidou renders through wgpu, which tries
  Vulkan first and falls back to GL. Software rasterizers (lavapipe, llvmpipe)
  are accepted, so it can run in a VM, but see the note below.
- **x86_64 or aarch64.** Other architectures build from source.
- `xdg-desktop-portal` for native file dialogs.

Set `SHIDOU_VERSION` to install a specific version rather than the latest.

## Installing manually

The script is a convenience, not a requirement. Download
`shidou-<version>-<target>.tar.gz` from
[GitHub Releases](https://github.com/noelrohi/shidou/releases), then unpack it
wherever you like. The release bucket serves individual files, not a download
index; `https://releases.shidou.dev/latest-linux.txt` names the current version.

```sh
mkdir -p ~/.local/shidou.app
tar -xzf shidou-<version>-<target>.tar.gz --strip-components=1 -C ~/.local/shidou.app
ln -sf ~/.local/shidou.app/bin/shidou ~/.local/bin/shidou   # optional
```

The archive uses an install-prefix layout (`bin/`, `share/`) beneath one
versioned directory, so `--strip-components=1` into a prefix such as
`/usr/local` works too.

The matching source is published beside it as
`shidou-<version>-source.tar.gz`.

**Keep `bin/` intact.** Shidou launches `shidou-daemon` from its own directory, so
copying `bin/shidou` somewhere on its own leaves it unable to start the daemon.
A symlink is fine — Shidou resolves it back to the real path.

Installing the desktop entry is the part that matters — it is how the app is
launched normally, and it is what associates the running window with its icon
and name (Shidou reports the Wayland `app_id` / X11 `WM_CLASS` `dev.shidou`, which
matches the entry's filename). Install the packaged file and point it at the
install (the packaged copy uses bare `Exec=shidou` and `Icon=dev.shidou` names so it
can be relocated):

```sh
install -D ~/.local/shidou.app/share/applications/dev.shidou.desktop \
  -t ~/.local/share/applications
sed -i "s|^Exec=shidou$|Exec=$HOME/.local/shidou.app/bin/shidou|" \
  ~/.local/share/applications/dev.shidou.desktop
sed -i "s|^Icon=dev.shidou$|Icon=$HOME/.local/shidou.app/share/icons/hicolor/256x256/apps/dev.shidou.png|" \
  ~/.local/share/applications/dev.shidou.desktop
```

## Updating

Shidou does not update itself on Linux — Sparkle is macOS-only. Re-run the
install script to upgrade.

## Uninstalling

```sh
curl -fsSL https://shidou.dev/install.sh | sh -s -- --uninstall
```

This removes `~/.local/shidou.app`, the symlink, and the desktop entry. It
preserves your data and settings:

| What | Default release path |
| --- | --- |
| Task history and transcripts | `${XDG_DATA_HOME:-~/.local/share}/Shidou/app.db` |
| Attachments and blobs | `${XDG_DATA_HOME:-~/.local/share}/Shidou/blobs` |
| Desktop settings | `~/.shidou/app.json` |
| Daemon settings | `~/.shidou/settings.json` |
| Projectless task workspaces | `~/.shidou/projects` |

Here `XDG_DATA_HOME` defaults to `~/.local/share` when unset. To remove retained
Shidou data, stop the app and daemon, back up anything you need, then remove
both the `Shidou` data directory and `~/.shidou`. Removing `~/.shidou` alone
does **not** erase task history or attachments. These paths refer to the local
daemon; uninstalling a client does not erase data on a remote daemon or
provider-native history. Existing project folders elsewhere are left alone.

## Building from source

See [CONTRIBUTING.md](../CONTRIBUTING.md) for build prerequisites, then
produce the same archive this page installs with:

```sh
./scripts/bundle-linux.sh
```

To exercise the install script against that local build:

```sh
SHIDOU_BUNDLE_PATH=target/release/shidou-<version>-<target>.tar.gz \
  sh website/public/install.sh
```

## Running in a virtual machine

VMs usually have no GPU passthrough, so Mesa falls back to a software
rasterizer. That works in principle — wgpu accepts a CPU adapter — but both
lavapipe (Vulkan) and llvmpipe (GL) JIT-compile shaders through LLVM, and that
path is fragile: on Fedora 44 aarch64 (mesa 26.0.3 + LLVM 22.1) it segfaults
inside `gallivm_jit_function` while compiling a fragment shader. The crash is
in the driver, not in Shidou, and no application-side setting avoids it.

If the app dies on its first frame in a VM, check `coredumpctl info` for a
backtrace through `libvulkan_lvp.so` or `libgallium`. The reliable fix is to
give the guest a real GL driver — on UTM that means the QEMU backend with
virtio-gpu-gl (virgl) rather than Apple Virtualization, which offers Linux
guests no 3D at all. `VK_DRIVER_FILES=/nonexistent.json` hides the software
Vulkan driver so wgpu takes the GL path instead.

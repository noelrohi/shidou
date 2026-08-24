#!/usr/bin/env sh
set -eu

# Installs Shidou for Linux into ~/.local — no root, no package manager.
# Downloads the release tarball from https://releases.shidou.dev, unpacks it as
# ~/.local/shidou.app, links the binary onto PATH, and registers the desktop
# entry. docs/linux.md documents the equivalent manual steps.
#
#   curl -fsSL https://shidou.dev/install.sh | sh
#
# Environment:
#   SHIDOU_VERSION        install this version instead of the latest
#   SHIDOU_BUNDLE_PATH    install a local tarball instead of downloading
#   SHIDOU_RELEASES_URL   base URL to download from

usage() {
    cat <<'USAGE'
Install Shidou for Linux into ~/.local.

Usage:
  curl -fsSL https://shidou.dev/install.sh | sh
  curl -fsSL https://shidou.dev/install.sh | sh -s -- --uninstall

Options:
  --uninstall   Remove Shidou, leaving ~/.shidou (projects and settings) alone
  --help        Show this help
USAGE
}

main() {
    app_dir="$HOME/.local/shidou.app"
    bin_link="$HOME/.local/bin/shidou"
    desktop_file="$HOME/.local/share/applications/dev.shidou.desktop"
    releases="${SHIDOU_RELEASES_URL:-https://releases.shidou.dev}"

    case "${1:-}" in
        --uninstall) uninstall; return ;;
        --help | -h) usage; return ;;
        "") ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac

    platform="$(uname -s)"
    if [ "$platform" = "Darwin" ]; then
        echo "Shidou for macOS ships as a signed .dmg that updates itself." >&2
        echo "Download it from https://shidou.dev" >&2
        exit 1
    fi
    if [ "$platform" != "Linux" ]; then
        echo "Unsupported platform: $platform" >&2
        exit 1
    fi

    machine="$(uname -m)"
    case "$machine" in
        x86_64) target="x86_64-unknown-linux-gnu" ;;
        aarch64 | arm64) target="aarch64-unknown-linux-gnu" ;;
        *)
            echo "Unsupported architecture: $machine" >&2
            echo "Build from source: https://github.com/noelrohi/shidou" >&2
            exit 1
            ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        fetch() { command curl -fsSL "$1"; }
    elif command -v wget >/dev/null 2>&1; then
        fetch() { wget -qO- "$1"; }
    else
        echo "Could not find 'curl' or 'wget' in your PATH." >&2
        exit 1
    fi

    temp="$(mktemp -d "${TMPDIR:-/tmp}/shidou-XXXXXX")"
    staging="$app_dir.new"
    trap 'rm -rf -- "$temp" "$staging"' EXIT INT TERM

    archive="$temp/shidou.tar.gz"
    if [ -n "${SHIDOU_BUNDLE_PATH:-}" ]; then
        cp "$SHIDOU_BUNDLE_PATH" "$archive"
    else
        version="${SHIDOU_VERSION:-}"
        if [ -z "$version" ]; then
            if ! version="$(fetch "$releases/latest-linux.txt")"; then
                echo "Could not reach $releases/latest-linux.txt." >&2
                echo "Pass SHIDOU_VERSION to install a specific version." >&2
                exit 1
            fi
            version="$(printf '%s' "$version" | tr -d '[:space:]')"
        fi
        if [ -z "$version" ]; then
            echo "No Shidou version published for Linux yet." >&2
            exit 1
        fi
        echo "Downloading Shidou $version for $machine"
        if ! fetch "$releases/shidou-$version-$target.tar.gz" >"$archive"; then
            echo "Download failed: $releases/shidou-$version-$target.tar.gz" >&2
            exit 1
        fi
    fi
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        echo "Downloaded file is not a readable tarball." >&2
        exit 1
    fi

    # Unpack beside the target and swap only once the contents check out, so a
    # truncated download cannot leave a working install in pieces. The tarball
    # holds one versioned top-level directory; stripping it keeps every install
    # at the same path.
    echo "Installing to $app_dir"
    rm -rf "$staging"
    mkdir -p "$staging" "$(dirname "$bin_link")" "$(dirname "$desktop_file")"
    tar -xzf "$archive" --strip-components=1 -C "$staging"

    # Shidou resolves shidou-daemon next to its own executable, so the two must
    # stay together in bin/. Linking only the binary onto PATH is safe —
    # current_exe() resolves the symlink back into shidou.app.
    for binary in shidou shidou-daemon; do
        if [ ! -x "$staging/bin/$binary" ]; then
            echo "Archive is missing bin/$binary." >&2
            exit 1
        fi
    done
    # Replace rather than merge: a file dropped from a later layout must not
    # survive the upgrade.
    rm -rf "$app_dir"
    mv "$staging" "$app_dir"
    ln -sf "$app_dir/bin/shidou" "$bin_link"

    entry="$app_dir/share/applications/dev.shidou.desktop"
    if [ -f "$entry" ]; then
        # The packaged entry is relocatable (bare Exec/Icon names). Pin both to
        # this install so the launcher works without PATH or icon-theme setup.
        sed -e "s|^Exec=shidou$|Exec=$app_dir/bin/shidou|" \
            -e "s|^Icon=dev.shidou$|Icon=$app_dir/share/icons/hicolor/256x256/apps/dev.shidou.png|" \
            "$entry" >"$desktop_file"
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$(dirname "$desktop_file")" 2>/dev/null || true
        fi
    fi

    # Shidou is a desktop app and takes no arguments, so the launcher entry is
    # the way in. The PATH link is a convenience for starting it from a
    # terminal to watch its output.
    echo "Shidou is installed."
    if [ -f "$desktop_file" ]; then
        echo "Open it from your applications menu."
    fi
    if [ "$(command -v shidou || true)" = "$bin_link" ]; then
        echo "From a terminal: shidou"
    else
        echo "From a terminal: $bin_link"
    fi
}

uninstall() {
    if [ ! -d "$app_dir" ] && [ ! -L "$bin_link" ]; then
        echo "Shidou is not installed at $app_dir." >&2
        exit 1
    fi
    # Only reclaim the symlink and desktop entry this script created; a
    # distro package's copies of both belong to the package manager.
    if [ "$(readlink "$bin_link" 2>/dev/null || true)" = "$app_dir/bin/shidou" ]; then
        rm -f "$bin_link"
    fi
    if [ -f "$desktop_file" ] && grep -qF "$app_dir/bin/shidou" "$desktop_file"; then
        rm -f "$desktop_file"
    fi
    rm -rf "$app_dir"
    echo "Shidou is uninstalled. Projects and settings remain in ~/.shidou."
}

main "$@"

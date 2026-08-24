#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

target_dir="${CARGO_TARGET_DIR:-target}"
version="$(cargo metadata --no-deps --format-version 1 | sed -n 's/.*"name":"shidou","version":"\([^"]*\)".*/\1/p')"
target_triple="$(rustc -vV | sed -n 's/^host: //p')"
package="shidou-${version}-${target_triple}"
archive="$target_dir/release/$package.tar.gz"
staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT

cargo build --locked --release --package shidou --bin shidou --package shidou-daemon --bin shidou-daemon

package_dir="$staging/$package"
install -Dm755 "$target_dir/release/shidou" "$package_dir/bin/shidou"
install -Dm755 "$target_dir/release/shidou-daemon" "$package_dir/bin/shidou-daemon"
install -Dm644 resources/linux/dev.shidou.desktop \
  "$package_dir/share/applications/dev.shidou.desktop"
install -Dm644 website/public/app-icon.png \
  "$package_dir/share/icons/hicolor/256x256/apps/dev.shidou.png"
license_dir="$package_dir/share/licenses/shidou"
install -Dm644 LICENSE "$license_dir/LICENSE"
install -Dm644 THIRD_PARTY_NOTICES.md "$license_dir/THIRD_PARTY_NOTICES.md"
install -Dm644 licenses/THIRD_PARTY_RUST_LICENSES.html \
  "$license_dir/THIRD_PARTY_RUST_LICENSES.html"
install -Dm644 assets/fonts/OFL.txt "$license_dir/OFL.txt"
install -Dm644 assets/fonts/LICENSE-nerd-fonts.txt \
  "$license_dir/LICENSE-nerd-fonts.txt"

mkdir -p "$(dirname "$archive")"
tar -C "$staging" -czf "$archive" "$package"
for required in \
  "$package/share/licenses/shidou/LICENSE" \
  "$package/share/licenses/shidou/THIRD_PARTY_NOTICES.md" \
  "$package/share/licenses/shidou/THIRD_PARTY_RUST_LICENSES.html"; do
  tar -tzf "$archive" | grep -Fqx "$required"
done
printf 'Created %s\n' "$archive"

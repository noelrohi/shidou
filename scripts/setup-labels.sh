#!/usr/bin/env bash
# Create the pull-request labels scripts/pr-check.ts expects. Idempotent;
# run once per repository (see RELEASING.md, "One-time setup").
set -euo pipefail

repo="${1:-noelrohi/shidou}"

label() {
  gh label create "$1" --repo "$repo" --color "$2" --description "$3" --force
}

label app:desktop      1d76db "Changes the Desktop Client (macOS, Linux, Windows) or its bundled Daemon"
label app:ios          5319e7 "Changes the iOS Client"
label app:browser      0e8a16 "Changes the Browser Client"
label app:website      fbca04 "Changes the marketing website"
label no-release       cfd3d7 "No user-visible change ships from this pull request"
label protocol:breaking b60205 "Changes PROTOCOL_VERSION; Desktop, iOS, and Browser must ship together"

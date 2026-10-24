#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../path-utils.sh"
LIVE_REPO_ROOT="$SCRIPT_DIR/../../.."
output_parent=$(live_fixture_output_parent "$@")
target="$output_parent/F-unreadable"
if [[ -e "$target" || -L "$target" ]]; then
  if [[ ! -d "$target" || -L "$target" ]] || [[ -n "$(find "$target" -mindepth 1 -print -quit)" ]]; then
    printf 'refusing to overwrite non-empty fixture target: %s\n' "$target" >&2
    exit 1
  fi
fi
mkdir -p "$target"

if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to create the worktree fixture\n' >&2
  exit 1
fi

repo="$target/ghq/example.test/org/unreadable-repo"
checkout="$target/checkouts/unreadable"
mkdir -p "$target/ghq/example.test/org" "$target/checkouts"
jj git init --colocate "$repo"
printf 'fixture base\n' > "$repo/tracked.txt"
jj -R "$repo" describe -m 'F-unreadable base'
jj -R "$repo" new
jj -R "$repo" workspace add "$checkout" --name unreadable --colocate
chmod 000 "$checkout"

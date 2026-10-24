#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  printf 'usage: %s OUTPUT_PARENT\n' "${0##*/}" >&2
  exit 2
fi

output_parent=$1
target="$output_parent/F-missing"
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

repo="$target/ghq/example.test/org/missing-repo"
mkdir -p "$target/ghq/example.test/org" "$target/checkouts" "$target/archive"
jj git init --colocate "$repo"
printf 'fixture base\n' > "$repo/tracked.txt"
jj -R "$repo" describe -m 'F-missing base'
jj -R "$repo" new

jj -R "$repo" workspace add "$target/checkouts/removed" --name removed --colocate
jj -R "$repo" workspace add "$target/checkouts/locked" --name locked --colocate
jj -R "$repo" workspace add "$target/checkouts/prunable" --name prunable --colocate

printf 'fixture lock\n' > "$repo/.git/worktrees/locked/locked"
mv "$target/checkouts/removed" "$target/archive/removed"
mv "$target/checkouts/prunable/.git" "$target/archive/prunable.git"

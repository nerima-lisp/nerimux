#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  printf 'usage: %s OUTPUT_PARENT\n' "${0##*/}" >&2
  exit 2
fi

output_parent=$1
target="$output_parent/F-escape"
if [[ -e "$target" || -L "$target" ]]; then
  if [[ ! -d "$target" || -L "$target" ]] || [[ -n "$(find "$target" -mindepth 1 -print -quit)" ]]; then
    printf 'refusing to overwrite non-empty fixture target: %s\n' "$target" >&2
    exit 1
  fi
fi
mkdir -p "$target"

if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to create the repository fixture\n' >&2
  exit 1
fi

repo="$target/ghq/example.test/org/escape-repo"
mkdir -p "$target/ghq/example.test/org" "$target/outside"
jj git init --colocate "$repo"
printf 'escape target\n' > "$target/outside/fixture.txt"
ln -s ../../../../outside "$repo/escape-link"

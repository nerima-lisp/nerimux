#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  printf 'usage: %s OUTPUT_PARENT\n' "${0##*/}" >&2
  exit 2
fi

output_parent=$1
target="$output_parent/F-empty"
if [[ -e "$target" || -L "$target" ]]; then
  if [[ ! -d "$target" || -L "$target" ]] || [[ -n "$(find "$target" -mindepth 1 -print -quit)" ]]; then
    printf 'refusing to overwrite non-empty fixture target: %s\n' "$target" >&2
    exit 1
  fi
fi
mkdir -p "$target/ghq"

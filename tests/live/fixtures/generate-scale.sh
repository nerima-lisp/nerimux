#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )) || [[ -z ${1:-} ]]; then
  printf 'usage: %s OUTPUT_ROOT\n' "${0##*/}" >&2
  exit 64
fi
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-scale\n' >&2
  exit 127
fi

output_root=$1
mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)
fixture_root="$output_root/F-scale"

if [[ -L $fixture_root || ( -e $fixture_root && ! -d $fixture_root ) ]]; then
  printf '%s is not a usable fixture directory\n' "$fixture_root" >&2
  exit 73
fi
if [[ -d $fixture_root ]]; then
  shopt -s dotglob nullglob
  existing_entries=("$fixture_root"/*)
  shopt -u dotglob nullglob
  if (( ${#existing_entries[@]} > 0 )); then
    printf '%s is not empty; refusing to overwrite it\n' "$fixture_root" >&2
    exit 73
  fi
fi

mkdir -p "$fixture_root/ghq/example.test/org"

jj_fixture() {
  jj --quiet --config user.name=Fixture --config user.email=fixture "$@"
}

for ((number = 1; number <= 100; number++)); do
  printf -v repo_number '%03d' "$number"
  repo="$fixture_root/ghq/example.test/org/repo-$repo_number"
  jj_fixture git init --colocate "$repo" >/dev/null
  printf 'scale fixture repository %s\n' "$repo_number" > "$repo/fixture.txt"
  jj_fixture -R "$repo" commit -m 'scale fixture baseline' >/dev/null
  mkdir -p "$repo/.worktrees"
  jj_fixture -R "$repo" workspace add --colocate --name second "$repo/.worktrees/second" >/dev/null
  jj_fixture -R "$repo" workspace add --colocate --name third "$repo/.worktrees/third" >/dev/null
done

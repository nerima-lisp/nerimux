#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )) || [[ -z ${1:-} ]]; then
  printf 'usage: %s OUTPUT_PARENT\n' "${0##*/}" >&2
  exit 64
fi
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-conflict\n' >&2
  exit 127
fi

output_parent=$1
mkdir -p "$output_parent"
output_parent=$(cd "$output_parent" && pwd -P)
fixture_root="$output_parent/F-conflict"
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

mkdir -p "$fixture_root"
repo="$fixture_root/ghq/example.test/org/conflict-repo"
mkdir -p "${repo%/*}"

jj_fixture() {
  jj --quiet --config user.name=Fixture --config user.email=fixture "$@"
}

jj_fixture git init --colocate "$repo" >/dev/null
printf 'common base\n' > "$repo/conflict.txt"
jj_fixture -R "$repo" commit -m 'F-conflict base' >/dev/null
jj_fixture -R "$repo" bookmark create main -r @- >/dev/null

jj_fixture -R "$repo" new main >/dev/null
printf 'ours\n' > "$repo/conflict.txt"
jj_fixture -R "$repo" commit -m 'F-conflict ours' >/dev/null
jj_fixture -R "$repo" bookmark create feature/ours -r @- >/dev/null

jj_fixture -R "$repo" new main >/dev/null
printf 'theirs\n' > "$repo/conflict.txt"
jj_fixture -R "$repo" commit -m 'F-conflict theirs' >/dev/null
jj_fixture -R "$repo" bookmark create feature/theirs -r @- >/dev/null
theirs_commit=$(jj_fixture -R "$repo" log --no-pager --no-graph -r feature/theirs --template 'commit_id')

jj_fixture -R "$repo" new feature/ours feature/theirs >/dev/null
printf 'ref: refs/heads/feature/ours\n' > "$repo/.git/HEAD"
printf '%s\n' "$theirs_commit" > "$repo/.git/MERGE_HEAD"

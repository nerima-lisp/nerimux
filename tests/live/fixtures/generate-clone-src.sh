#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )) || [[ -z ${1:-} ]]; then
  printf 'usage: %s OUTPUT_ROOT\n' "${0##*/}" >&2
  exit 64
fi
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-clone-src\n' >&2
  exit 127
fi

output_root=$1
mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)
fixture_root="$output_root/F-clone-src"

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
build_root="$fixture_root/.jj-build"
bare_repo="$fixture_root/source.git"

jj_fixture() {
  jj --quiet --config user.name=Fixture --config user.email=fixture "$@"
}

jj_fixture git init --colocate "$build_root" >/dev/null
printf 'local clone source fixture\n' > "$build_root/README.md"
jj_fixture -R "$build_root" commit -m 'local clone source fixture' >/dev/null
jj_fixture -R "$build_root" bookmark create main -r @- >/dev/null

mkdir -p "$bare_repo"
cp -R "$build_root/.git/." "$bare_repo/"
awk '
  /^[[:space:]]*bare = false[[:space:]]*$/ {
    print "\tbare = true"
    replaced++
    next
  }
  { print }
  END { if (replaced != 1) exit 1 }
' "$bare_repo/config" > "$bare_repo/config.new"
mv "$bare_repo/config.new" "$bare_repo/config"
printf 'ref: refs/heads/main\n' > "$bare_repo/HEAD"

rm -rf "$build_root"

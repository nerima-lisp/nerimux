#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../path-utils.sh"
LIVE_REPO_ROOT="$SCRIPT_DIR/../../.."
output_parent=$(live_fixture_output_parent "$@")
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-dirty\n' >&2
  exit 127
fi

fixture_root="$output_parent/F-dirty"
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
seed="$fixture_root/support/seed"
origin="$fixture_root/support/dirty-origin"
repo="$fixture_root/ghq/example.test/org/dirty-repo"

jj_fixture() {
  jj --quiet --config user.name=Fixture --config user.email=fixture "$@"
}

mkdir -p "${seed%/*}" "${repo%/*}"
jj_fixture git init --no-colocate "$seed" >/dev/null
printf 'tracked baseline\n' > "$seed/modified.txt"
printf 'remove this file\n' > "$seed/deleted.txt"
printf 'rename this file\n' > "$seed/rename-source.txt"
printf 'dash filename\n' > "$seed/-dash"
jj_fixture -R "$seed" commit -m 'F-dirty base' >/dev/null
jj_fixture -R "$seed" bookmark create main -r @- >/dev/null
jj_fixture -R "$seed" git export >/dev/null

mkdir -p "$origin"
cp -R "$seed/.jj/repo/store/git/." "$origin/"
printf 'ref: refs/heads/main\n' > "$origin/HEAD"
jj_fixture git clone --colocate --branch main "$origin" "$repo" >/dev/null
jj_fixture -R "$repo" git remote remove origin >/dev/null
printf 'ref: refs/heads/main\n' > "$repo/.git/HEAD"

printf 'tracked addition\n' > "$repo/added.txt"
printf 'modified baseline\n' > "$repo/modified.txt"
rm "$repo/deleted.txt"
mv "$repo/rename-source.txt" "$repo/renamed.txt"
jj_fixture -R "$repo" status >/dev/null
jj_fixture -R "$repo" commit -m 'F-dirty staged changes' >/dev/null
printf 'ref: refs/heads/main\n' > "$repo/.git/HEAD"
printf 'untracked fixture data\n' > "$repo/untracked.txt"

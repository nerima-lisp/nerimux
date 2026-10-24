#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../path-utils.sh"
LIVE_REPO_ROOT="$SCRIPT_DIR/../../.."
output_parent=$(live_fixture_output_parent "$@")
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-behind\n' >&2
  exit 127
fi

fixture_root="$output_parent/F-behind"
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
origin="$fixture_root/support/behind-origin"
origin_state="$fixture_root/support/origin-state"
repo="$fixture_root/ghq/example.test/org/behind-repo"

jj_fixture() {
  jj --quiet --config user.name=Fixture --config user.email=fixture "$@"
}

mkdir -p "${seed%/*}" "${origin%/*}" "${repo%/*}"
jj_fixture git init --no-colocate "$seed" >/dev/null
printf 'shared base\n' > "$seed/base.txt"
jj_fixture -R "$seed" commit -m 'F-behind shared base' >/dev/null
jj_fixture -R "$seed" bookmark create main -r @- >/dev/null
jj_fixture -R "$seed" git export >/dev/null

cp -R "$seed/.jj/repo/store/git/." "$origin/"
printf 'ref: refs/heads/main\n' > "$origin/HEAD"
jj_fixture git clone --colocate --branch main "$origin" "$repo" >/dev/null
jj_fixture -R "$repo" new main >/dev/null
printf 'local ahead\n' > "$repo/local-ahead.txt"
jj_fixture -R "$repo" commit -m 'F-behind local ahead' >/dev/null
jj_fixture -R "$repo" bookmark set main -r @- >/dev/null

jj_fixture git init --git-repo "$origin" --no-colocate "$origin_state" >/dev/null
jj_fixture -R "$origin_state" new main >/dev/null
printf 'remote behind\n' > "$origin_state/remote-behind.txt"
jj_fixture -R "$origin_state" commit -m 'F-behind remote advance' >/dev/null
jj_fixture -R "$origin_state" bookmark set main -r @- >/dev/null
jj_fixture -R "$origin_state" git export >/dev/null

(cd "$repo" && jj_fixture -R "$repo" git remote remove origin >/dev/null)
(cd "$repo" && jj_fixture -R "$repo" git remote add origin ../../../../support/behind-origin >/dev/null)
(cd "$repo" && jj_fixture -R "$repo" git fetch --remote origin --branch main >/dev/null)
printf 'ref: refs/heads/main\n' > "$repo/.git/HEAD"
awk '
  /^\[remote "origin"\]$/ { in_origin = 1; print; next }
  /^\[/ { in_origin = 0 }
  in_origin && /^[[:space:]]*url = / {
    print "\turl = ../../../../support/behind-origin"
    replaced++
    next
  }
  { print }
  END { if (replaced != 1) exit 1 }
' "$repo/.git/config" > "$repo/.git/config.new"
mv "$repo/.git/config.new" "$repo/.git/config"
cat >> "$repo/.git/config" <<'CONFIG'

[branch "main"]
	remote = origin
	merge = refs/heads/main
CONFIG

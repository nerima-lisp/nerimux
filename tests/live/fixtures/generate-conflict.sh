#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../path-utils.sh"
LIVE_REPO_ROOT="$SCRIPT_DIR/../../.."
output_parent=$(live_fixture_output_parent "$@")
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-conflict\n' >&2
  exit 127
fi

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

rebase_repo="$fixture_root/ghq/example.test/org/rebase-repo"
mkdir -p "${rebase_repo%/*}"
jj_fixture git init --colocate "$rebase_repo" >/dev/null
printf 'common base\n' > "$rebase_repo/conflict.txt"
jj_fixture -R "$rebase_repo" commit -m 'F-rebase base' >/dev/null
jj_fixture -R "$rebase_repo" bookmark create main -r @- >/dev/null

jj_fixture -R "$rebase_repo" new main >/dev/null
printf 'ours\n' > "$rebase_repo/conflict.txt"
jj_fixture -R "$rebase_repo" commit -m 'F-rebase ours' >/dev/null
jj_fixture -R "$rebase_repo" bookmark create feature/rebase-ours -r @- >/dev/null
ours_commit=$(jj_fixture -R "$rebase_repo" log --no-pager --no-graph -r feature/rebase-ours --template 'commit_id')

jj_fixture -R "$rebase_repo" new main >/dev/null
printf 'theirs\n' > "$rebase_repo/conflict.txt"
jj_fixture -R "$rebase_repo" commit -m 'F-rebase theirs' >/dev/null
jj_fixture -R "$rebase_repo" bookmark create feature/rebase-theirs -r @- >/dev/null
theirs_commit=$(jj_fixture -R "$rebase_repo" log --no-pager --no-graph -r feature/rebase-theirs --template 'commit_id')

jj_fixture -R "$rebase_repo" new feature/rebase-theirs feature/rebase-ours >/dev/null
mkdir -p "$rebase_repo/.git/rebase-merge"
printf 'refs/heads/feature/rebase-ours\n' > "$rebase_repo/.git/rebase-merge/head-name"
printf '%s\n' "$theirs_commit" > "$rebase_repo/.git/rebase-merge/onto"
printf '%s\n' "$ours_commit" > "$rebase_repo/.git/rebase-merge/orig-head"
printf '1\n' > "$rebase_repo/.git/rebase-merge/msgnum"
printf '1\n' > "$rebase_repo/.git/rebase-merge/end"
printf 'pick %s F-rebase ours\n' "$ours_commit" > "$rebase_repo/.git/rebase-merge/done"
: > "$rebase_repo/.git/rebase-merge/git-rebase-todo"
printf '%s\n' "$ours_commit" > "$rebase_repo/.git/rebase-merge/stopped-sha"
printf '%s\n' "$theirs_commit" > "$rebase_repo/.git/HEAD"
printf '%s\n' "$ours_commit" > "$rebase_repo/.git/REBASE_HEAD"
printf '%s\n' "$ours_commit" > "$rebase_repo/.git/ORIG_HEAD"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../path-utils.sh"
LIVE_REPO_ROOT="$SCRIPT_DIR/../../.."
output_parent=$(live_fixture_output_parent "$@")
if ! command -v jj >/dev/null 2>&1; then
  printf 'jj is required to generate F-bare\n' >&2
  exit 127
fi

fixture_root="$output_parent/F-bare"
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
state="$fixture_root/support/bare-state"
bare_repo="$fixture_root/ghq/example.test/org/bare-repo"

jj_fixture() {
  jj --quiet --config user.name=Fixture --config user.email=fixture "$@"
}

mkdir -p "${seed%/*}" "${bare_repo%/*}"
jj_fixture git init --no-colocate "$seed" >/dev/null
printf 'bare fixture base\n' > "$seed/README.md"
jj_fixture -R "$seed" commit -m 'F-bare base' >/dev/null
jj_fixture -R "$seed" bookmark create main -r @- >/dev/null

jj_fixture -R "$seed" new main >/dev/null
printf 'alpha worktree\n' > "$seed/alpha.txt"
jj_fixture -R "$seed" commit -m 'F-bare alpha branch' >/dev/null
jj_fixture -R "$seed" bookmark create feature/alpha -r @- >/dev/null

jj_fixture -R "$seed" new main >/dev/null
printf 'beta worktree\n' > "$seed/beta.txt"
jj_fixture -R "$seed" commit -m 'F-bare beta branch' >/dev/null
jj_fixture -R "$seed" bookmark create feature/beta -r @- >/dev/null

jj_fixture -R "$seed" new main >/dev/null
printf 'detached worktree\n' > "$seed/detached.txt"
jj_fixture -R "$seed" commit -m 'F-bare detached revision' >/dev/null
jj_fixture -R "$seed" bookmark create fixture/detached -r @- >/dev/null
jj_fixture -R "$seed" git export >/dev/null

mkdir -p "$bare_repo"
cp -R "$seed/.jj/repo/store/git/." "$bare_repo/"
printf 'ref: refs/heads/main\n' > "$bare_repo/HEAD"
mkdir -p "$bare_repo/.worktrees"
jj_fixture git init --git-repo "$bare_repo" --no-colocate "$state" >/dev/null

jj_fixture -R "$state" workspace add --colocate --name alpha --revision feature/alpha "$bare_repo/.worktrees/alpha" >/dev/null
jj_fixture -R "$state" workspace add --colocate --name beta --revision feature/beta "$bare_repo/.worktrees/beta" >/dev/null
jj_fixture -R "$state" workspace add --colocate --name detached --revision fixture/detached "$bare_repo/.worktrees/detached" >/dev/null
jj_fixture -R "$state" bookmark delete fixture/detached >/dev/null
jj_fixture -R "$state" git export >/dev/null

printf 'ref: refs/heads/feature/alpha\n' > "$bare_repo/worktrees/alpha/HEAD"
printf 'ref: refs/heads/feature/beta\n' > "$bare_repo/worktrees/beta/HEAD"

no_worktree_store="$fixture_root/support/no-worktree.git"
no_worktree_entry="$fixture_root/ghq/example.test/org/no-worktree-repo"
mkdir -p "$no_worktree_store" "$no_worktree_entry"
cp -R "$seed/.jj/repo/store/git/." "$no_worktree_store/"
printf 'ref: refs/heads/main\n' > "$no_worktree_store/HEAD"
ln -s "$no_worktree_store" "$no_worktree_entry/.git"

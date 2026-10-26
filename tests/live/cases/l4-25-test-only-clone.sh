#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/../../.." && pwd -P)
harness="$repo_root/tests/live/harness"
fixture_generator="$repo_root/tests/live/fixtures/generate-clone-src.sh"

if [[ $# -ne 2 ]]; then
  printf 'usage: bash %s <default-nerimux-binary> <test-local-clone-nerimux-binary>\n' "$0" >&2
  printf 'build with: nix build --offline --no-link --print-out-paths . and nix build --offline --no-link --print-out-paths .#nerimux-test-local-clone\n' >&2
  exit 2
fi

default_binary=$1
test_binary=$2
for binary in "$default_binary" "$test_binary"; do
  if [[ ! -x $binary ]]; then
    printf 'nerimux binary is not executable: %s\n' "$binary" >&2
    exit 2
  fi
done

lane=L8
live_parent=${LIVE_BASE_TMPDIR:-${TMPDIR:-/tmp}/nmx-live}
mkdir -p "$live_parent"
live_base=$(mktemp -d "$live_parent/l4-25-run.XXXXXX")
export LIVE_BASE_TMPDIR="$live_base"
lane_root="$live_base/$lane"
evidence="$lane_root/evidence/cases"
mkdir -p "$lane_root/fixtures" "$evidence"
fixture_parent=$(mktemp -d "$lane_root/fixtures/l4-25.XXXXXX")
"$fixture_generator" "$fixture_parent" >"$evidence/L4-25-fixture.log"
fixture_root=$(cd -- "$fixture_parent/F-clone-src" && pwd -P)
source_path="$fixture_root/source.git"
clone_path="$fixture_root/ghq/github.com/fixture/clone-source.git"

if [[ $source_path == *[[:space:]]* ]]; then
  printf 'fixture path contains whitespace and cannot be sent as a clone command: %s\n' "$source_path" >&2
  exit 2
fi
if [[ $(git -C "$source_path" rev-parse --is-bare-repository) != true ]]; then
  printf 'F-clone-src/source.git is not bare: %s\n' "$source_path" >&2
  exit 1
fi
if [[ -e $clone_path ]]; then
  printf 'clone destination already exists: %s\n' "$clone_path" >&2
  exit 1
fi

{
  printf 'default_binary=%s\n' "$default_binary"
  printf 'test_local_clone_binary=%s\n' "$test_binary"
  printf 'fixture_root=%s\n' "$fixture_root"
  printf 'source=%s\n' "$source_path"
  printf 'clone_destination=%s\n' "$clone_path"
} >"$evidence/L4-25-paths.txt"

export LIVE_FIXTURE_ROOT="$fixture_root"
unset GHQ_ROOT
export GIT_ALLOW_PROTOCOL=file
export GIT_PROTOCOL_FROM_USER=1
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=0
export GIT_TERMINAL_PROMPT=0

pre_stop="$evidence/L4-25-pre-stop.log"
if ! "$harness" stop "$lane" "$default_binary" >"$pre_stop" 2>&1; then
  if ! grep -Eqi 'no server running|no server|No such file or directory' "$pre_stop" "$lane_root/evidence/stop.log"; then
    cat "$pre_stop" >&2
    exit 1
  fi
fi

active_binary=$default_binary
cleanup() {
  status=$?
  trap - EXIT
  if ! "$harness" stop "$lane" "$active_binary" >"$evidence/L4-25-stop.log" 2>&1; then
    cat "$evidence/L4-25-stop.log" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

"$harness" start "$lane" "$default_binary" >"$evidence/L4-25-default-start.log"
"$harness" resize "$lane" 220 45
"$harness" wait-for "$lane" 'no repositories found' 30
"$harness" snap "$lane" L4-25-default-initial
"$harness" keys "$lane" : "clone $source_path" Enter
"$harness" wait-for "$lane" 'clone failed:' 30
"$harness" snap "$lane" L4-25-default-rejected
default_pane="$lane_root/evidence/snapshots/L4-25-default-rejected/pane.txt"
if ! grep -Fq 'unsupported clone source format' "$default_pane"; then
  cat "$default_pane" >&2
  printf 'default binary did not report local-path rejection\n' >&2
  exit 1
fi
if [[ -e $clone_path ]]; then
  printf 'default binary created a clone destination despite rejecting the local path\n' >&2
  exit 1
fi
"$harness" stop "$lane" "$default_binary" >"$evidence/L4-25-default-stop.log"

active_binary=$test_binary
"$harness" start "$lane" "$test_binary" >"$evidence/L4-25-test-only-start.log"
"$harness" resize "$lane" 220 45
"$harness" wait-for "$lane" 'no repositories found' 30
"$harness" snap "$lane" L4-25-test-only-initial
"$harness" keys "$lane" : "clone $source_path" Enter
"$harness" wait-for "$lane" 'worktree created:' 60
"$harness" snap "$lane" L4-25-test-only-complete

if [[ $(git -C "$clone_path" rev-parse --is-bare-repository) != true ]]; then
  printf 'test-only binary did not create the expected bare repository: %s\n' "$clone_path" >&2
  exit 1
fi
worktrees="$evidence/L4-25-worktrees.txt"
git -C "$clone_path" worktree list --porcelain | tee "$worktrees"
if ! grep -Fqx 'detached' "$worktrees"; then
  printf 'test-only binary did not create the default detached worktree\n' >&2
  exit 1
fi
worktree_count=$(grep -c '^worktree ' "$worktrees")
if (( worktree_count < 2 )); then
  printf 'expected the bare repository and its detached default worktree, found %s entries\n' "$worktree_count" >&2
  exit 1
fi

printf 'L4-25 PASS\n'

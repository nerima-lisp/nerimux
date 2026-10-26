#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/../../.." && pwd -P)
harness="$repo_root/tests/live/harness"

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <nerimux-binary> <F-behind-root>\n' "$0" >&2
  exit 2
fi

binary=$1
fixture_root=$(cd -- "$2" && pwd -P)
repo="$fixture_root/ghq/example.test/org/behind-repo"
lane=L8
live_base=${LIVE_BASE_TMPDIR:-${TMPDIR:-/tmp}/nmx-live}
lane_root="$live_base/$lane"
evidence="$lane_root/evidence/cases"
mkdir -p "$evidence"
unset GHQ_ROOT
export LIVE_FIXTURE_ROOT="$fixture_root"

pre_stop="$evidence/L4-18-pre-stop.log"
if ! "$harness" stop "$lane" "$binary" >"$pre_stop" 2>&1; then
  if ! grep -Eqi 'no server running|no server|No such file or directory' "$pre_stop" "$lane_root/evidence/stop.log"; then
    cat "$pre_stop" >&2
    exit 1
  fi
fi

cleanup() {
  status=$?
  trap - EXIT
  if ! "$harness" stop "$lane" "$binary" >"$evidence/L4-18-stop.log" 2>&1; then
    cat "$evidence/L4-18-stop.log" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

"$harness" start "$lane" "$binary" >"$evidence/L4-18-start.log"
"$harness" resize "$lane" 240 45
"$harness" wait-for "$lane" 'Repositories' 30
"$harness" snap "$lane" L4-18-initial
"$harness" keys "$lane" w b
"$harness" wait-for "$lane" 'remote origin/fixture/remote-only' 15
"$harness" snap "$lane" L4-18-branch-picker
"$harness" keys "$lane" C-n C-n Enter
"$harness" wait-for "$lane" 'worktree ready:' 30
"$harness" snap "$lane" L4-18-complete

git -C "$repo" branch -a -vv | tee "$evidence/L4-18-branches.txt"
if ! git -C "$repo" show-ref --verify --quiet refs/heads/fixture/remote-only; then
  printf 'local tracking branch was not created\n' >&2
  exit 1
fi
upstream=$(git -C "$repo" for-each-ref --format='%(upstream:short)' refs/heads/fixture/remote-only)
if [[ $upstream != origin/fixture/remote-only ]]; then
  printf 'unexpected upstream: %s\n' "$upstream" >&2
  exit 1
fi

worktree_info=$(git -C "$repo" worktree list --porcelain)
printf '%s\n' "$worktree_info" | tee "$evidence/L4-18-worktrees.txt"
printf '%s\n' "$worktree_info" | grep -Fq 'branch refs/heads/fixture/remote-only'
printf 'L4-18 PASS\n'

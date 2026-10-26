#!/usr/bin/env bash
set -euo pipefail

if [[ $(basename -- "$0") == nerimux ]]; then
  log="$GHQ_ROOT/.l4-22-app-env.txt"
  {
    printf 'TMPDIR=%s\n' "$TMPDIR"
    printf 'GHQ_ROOT=%s\n' "$GHQ_ROOT"
    printf 'PATH=%s\n' "$PATH"
  } >> "$log"
  exec "$0.real" "$@"
fi

if [[ $(basename -- "$0") == ghq ]]; then
  log="$GHQ_ROOT/.l4-22-ghq-child-env.txt"
  {
    printf 'TMPDIR=%s\n' "${TMPDIR:-}"
    printf 'GHQ_ROOT=%s\n' "${GHQ_ROOT:-}"
    printf 'arguments='
    printf ' %q' "$@"
    printf '\n'
  } >> "$log"
  if [[ ${1:-} == get ]]; then
    if [[ -d ${TMPDIR:-/missing} && -w $TMPDIR ]]; then
      printf 'TMPDIR_WRITABLE=yes\n' >> "$log"
    else
      printf 'TMPDIR_WRITABLE=no\n' >> "$log"
      exit 88
    fi
  fi
  exec "$0.real" "$@"
fi

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/../../.." && pwd -P)
harness="$repo_root/tests/live/harness"

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <nerimux-binary>\n' "$0" >&2
  exit 2
fi

binary=$1
lane=L8
live_base=${LIVE_BASE_TMPDIR:-${TMPDIR:-/tmp}/nmx-live}
lane_root="$live_base/$lane"
evidence="$lane_root/evidence/cases"
mkdir -p "$lane_root/fixtures" "$evidence"
fixture_parent=$(mktemp -d "$lane_root/fixtures/l4-22.XXXXXX")
"$repo_root/tests/live/fixtures/generate-empty.sh" "$fixture_parent" >"$evidence/L4-22-fixture.log"
fixture_root=$(cd -- "$fixture_parent/F-empty" && pwd -P)
mkdir -p "$fixture_root/bin"
export LIVE_FIXTURE_ROOT="$fixture_root"
unset GHQ_ROOT

real_ghq=$(type -P ghq || true)
if [[ -z $real_ghq || ! -x $real_ghq ]]; then
  printf 'ghq executable is required for L4-22\n' >&2
  exit 127
fi
ln -s "$real_ghq" "$fixture_root/bin/ghq.real"
ln -s "$binary" "$fixture_root/bin/nerimux.real"
cp "$0" "$fixture_root/bin/ghq"
cp "$0" "$fixture_root/bin/nerimux"
chmod +x "$fixture_root/bin/ghq" "$fixture_root/bin/nerimux"

pre_stop="$evidence/L4-22-pre-stop.log"
if ! "$harness" stop "$lane" "$binary" >"$pre_stop" 2>&1; then
  if ! grep -Eqi 'no server running|no server|No such file or directory' "$pre_stop" "$lane_root/evidence/stop.log"; then
    cat "$pre_stop" >&2
    exit 1
  fi
fi

cleanup() {
  status=$?
  trap - EXIT
  if ! "$harness" stop "$lane" "$binary" >"$evidence/L4-22-stop.log" 2>&1; then
    cat "$evidence/L4-22-stop.log" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

"$harness" start "$lane" "$fixture_root/bin/nerimux" >"$evidence/L4-22-start.log"
"$harness" resize "$lane" 180 45
"$harness" wait-for "$lane" 'nerimux' 30
"$harness" snap "$lane" L4-22-initial
"$harness" keys "$lane" : 'clone git@example.invalid:org/repo' Enter
"$harness" wait-for "$lane" 'clone failed:' 30
"$harness" snap "$lane" L4-22-after-failure

app_trace="$fixture_root/ghq/.l4-22-app-env.txt"
trace="$fixture_root/ghq/.l4-22-ghq-child-env.txt"
lane_tmp=$(cd -- "$lane_root/tmp" && pwd -P)
cp "$app_trace" "$evidence/L4-22-app-env.txt"
if [[ -f $trace ]]; then
  cp "$trace" "$evidence/L4-22-ghq-child-env.txt"
else
  printf 'ghq wrapper did not run; app environment follows\n' >&2
  cat "$app_trace" >&2
  exit 1
fi
grep -Fqx "TMPDIR=$lane_tmp" "$app_trace"
grep -Fqx "GHQ_ROOT=$fixture_root/ghq" "$app_trace"
pane="$lane_root/evidence/snapshots/L4-22-after-failure/pane.txt"
[[ -s $trace ]] || { printf 'ghq child environment was not captured\n' >&2; exit 1; }
if ! grep -Fq "arguments= get --bare --" "$trace"; then
  {
    printf "result: FAIL; clone did not reach ghq get\n"
    grep -F "message: clone failed:" "$pane" || true
    if grep -Fq "example.invalid/org" "$pane"; then
      printf "failed repository row: present\n"
    else
      printf "failed repository row: absent\n"
    fi
    if [[ -e "$fixture_root/ghq/example.invalid/org/repo.git" ]]; then
      printf "clone directory: present\n"
    else
      printf "clone directory: absent\n"
    fi
  } > "$evidence/L4-22-result.txt"
  cat "$trace" >&2
  cat "$evidence/L4-22-result.txt" >&2
  cat "$pane" >&2
  exit 1
fi
grep -Fqx "TMPDIR=$lane_tmp" "$trace"
grep -Fqx "GHQ_ROOT=$fixture_root/ghq" "$trace"
grep -Fqx 'TMPDIR_WRITABLE=yes' "$trace"
grep -Fq 'git@example.invalid:org/repo' "$trace"

if ! grep -Eiq 'clone failed:.*(Could not resolve hostname|nodename nor servname|Name or service not known|Temporary failure in name resolution|Name resolution failed)' "$pane"; then
  cat "$pane" >&2
  printf 'clone did not reach the expected .invalid DNS failure\n' >&2
  exit 1
fi
if grep -Fq 'example.invalid/org' "$pane"; then
  cat "$pane" >&2
  printf 'failed clone left a repository row\n' >&2
  exit 1
fi
if [[ -e "$fixture_root/ghq/example.invalid/org/repo.git" ]]; then
  printf 'failed clone left a repository directory\n' >&2
  exit 1
fi
printf 'L4-22 PASS\n'

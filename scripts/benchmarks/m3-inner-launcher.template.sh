#!/usr/bin/env bash
set -euo pipefail
source_root=@@SOURCE_ROOT@@
expected_source_sha=@@SOURCE_SHA@@
core_path=@@CORE_PATH@@
sbcl_path=@@SBCL_PATH@@
sbcl_home=@@SBCL_HOME@@
bootstrap=@@BOOTSTRAP@@
live_base=@@LIVE_BASE@@
probe_dir="$live_base/evidence/probe"
launcher=@@LAUNCHER@@
source_sha=$(jj --repository "$source_root" log --ignore-working-copy --no-graph -r '@' -T 'commit_id')
[[ "$source_sha" == "$expected_source_sha" ]] || exit 69
[[ -x "$sbcl_path" && -f "$core_path" && -f "$bootstrap" ]] || exit 68
parent_command=${M3_INNER_COMMAND:-}
case ${1:-} in
  attach)
    role=client
    command=attach
    parent_command=none
    session=
    ;;
  kill)
    role=client
    command=kill
    parent_command=none
    session=
    ;;
  server)
    role=server
    command=server
    [[ $parent_command == attach ]] || exit 67
    session=${2:?server session required}
    ;;
  *)
    exit 64
    ;;
esac
mkdir -p "$probe_dir"
if [[ $command != kill ]]; then
  for marker in server.armed server.done; do
    [[ ! -e "$probe_dir/$marker" ]] || exit 68
  done
fi
export M1_SOURCE_ROOT="$source_root"
export M1_SOURCE_SHA="$source_sha"
export M1_SCRATCH_ROOT="$(dirname "$bootstrap")"
export M3_INNER_ROLE="$role"
export M3_INNER_COMMAND="$command"
export M3_INNER_PARENT_COMMAND="$parent_command"
export M3_INNER_SESSION="$session"
export M3_INNER_LANE=L1
export M3_INNER_LAUNCHER="$launcher"
export M3_INNER_ARMED="$probe_dir/server.armed"
export M3_INNER_DONE="$probe_dir/server.done"
export M1_SBCL_PATH="$sbcl_path"
export SBCL_HOME="$sbcl_home"
export GIT_OPTIONAL_LOCKS=0
exec "$sbcl_path" --noinform --core "$core_path" --no-sysinit --load "$bootstrap" --no-userinit "$@"

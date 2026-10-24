#!/usr/bin/env bash
set -euo pipefail

(( $# == 2 || $# == 3 )) || { printf 'launch: expected binary, command, and optional stderr log\n' >&2; exit 2; }
binary=$1
command=$2
stderr_log=${3:-}
unset TMUX TMUX_PANE
if [[ -n $stderr_log ]]; then
  exec "$binary" "$command" 2> >(tee -a "$stderr_log" >&2)
fi
exec "$binary" "$command"

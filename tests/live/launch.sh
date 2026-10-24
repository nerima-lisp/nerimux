#!/usr/bin/env bash
set -euo pipefail

(( $# == 2 )) || { printf 'launch: expected binary and command\n' >&2; exit 2; }
binary=$1
command=$2
unset TMUX TMUX_PANE
exec "$binary" "$command"

#!/usr/bin/env bash

live_canonical_path() {
  local path=$1 current=/ component candidate
  local -a components

  [[ -n $path ]] || return 1
  [[ $path == /* ]] || path="$PWD/$path"
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    case $component in
      ''|.) continue ;;
      ..)
        if [[ $current != / ]]; then
          current=${current%/*}
          [[ -n $current ]] || current=/
        fi
        ;;
      *)
        if [[ $current == / ]]; then candidate="/$component"; else candidate="$current/$component"; fi
        if [[ -d $candidate ]]; then
          current=$(cd -P -- "$candidate" && pwd -P) || return
        elif [[ -e $candidate || -L $candidate ]]; then
          printf '%s is not a directory\n' "$candidate" >&2
          return 1
        else
          current=$candidate
        fi
        ;;
    esac
  done
  printf '%s' "$current"
}

live_external_path() {
  local path=$1 repo_root=$2 label=$3 canonical canonical_repo
  canonical_repo=$(cd -P -- "$repo_root" && pwd -P) || return
  canonical=$(live_canonical_path "$path") || return
  if [[ $canonical == "$canonical_repo" || $canonical == "$canonical_repo/"* ]]; then
    printf '%s must be outside the repository: %s\n' "$label" "$canonical" >&2
    return 1
  fi
  printf '%s' "$canonical"
}

live_fixture_output_parent() {
  local output_parent
  if (( $# > 1 )); then
    printf 'usage: %s [OUTPUT_PARENT]\n' "${0##*/}" >&2
    return 64
  fi
  if (( $# == 1 )); then
    [[ -n $1 ]] || { printf 'output parent must not be empty\n' >&2; return 64; }
    output_parent=$1
  else
    output_parent=${LIVE_FIXTURE_PARENT:-${LIVE_BASE_TMPDIR:-${TMPDIR:-/tmp}/nmx-live}/${LIVE_LANE:-default}/fixtures}
  fi
  live_external_path "$output_parent" "$LIVE_REPO_ROOT" 'fixture output parent'
}

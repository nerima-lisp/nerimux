#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )) || [[ -z ${1:-} ]]; then
  printf 'usage: %s OUTPUT_ROOT\n' "${0##*/}" >&2
  exit 64
fi

output_root=$1
mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)
fixture_root="$output_root/F-agents"

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

mkdir -p "$fixture_root/bin"

write_fake_agent() {
  local path=$1
  cat > "$path" <<'AGENT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s arguments:' "${0##*/}"
printf ' <%s>' "$@"
printf '\n%s waiting for input\n' "${0##*/}"
IFS= read -r agent_input || :
printf '%s received input\n' "${0##*/}"
printf '\a\033]9;fixture notification\007\033]99;fixture notification\007\033]999;unknown fixture notification\007\n'

if [[ -n ${NMX_FAKE_EXIT_CODE:-} ]]; then
  exit_code=$NMX_FAKE_EXIT_CODE
else
  agent_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  IFS= read -r exit_code < "$agent_dir/exit-code"
fi
if [[ ! $exit_code =~ ^[0-9]+$ ]] || (( ${#exit_code} > 3 )); then
  printf 'NMX_FAKE_EXIT_CODE must be between 0 and 255\n' >&2
  exit 64
fi
exit_code=$((10#$exit_code))
if (( exit_code > 255 )); then
  printf 'NMX_FAKE_EXIT_CODE must be between 0 and 255\n' >&2
  exit 64
fi
exit "$exit_code"
AGENT_SCRIPT
  chmod 755 "$path"
}

write_fake_agent "$fixture_root/bin/claude"
write_fake_agent "$fixture_root/bin/codex"
printf '0\n' > "$fixture_root/bin/exit-code"

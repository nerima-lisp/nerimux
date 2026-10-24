#!/usr/bin/env bash
set -euo pipefail

if (( $# != 1 )) || [[ -z ${1:-} ]]; then
  printf 'usage: %s OUTPUT_ROOT\n' "${0##*/}" >&2
  exit 64
fi

output_root=$1
mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd -P)
fixture_root="$output_root/F-term"

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
cat > "$fixture_root/run.sh" <<'TERM_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

printf '\033[?1049h'
printf '\033[2J\033[H'
printf '\033[38;5;196m256-color foreground\033[48;5;25m background\033[0m\n'
printf '\033[38;2;24;180;220mtruecolor foreground\033[48;2;60;30;90m background\033[0m\n'
printf '\033[2;20rscroll region\n'
printf '\033(0lqqqqqqqqk\n x        x\n mqqqqqqqqj\033(B\n'
printf 'wide CJK: 日本語の表示\n'
printf '\033]133;A\007\033]133;B\007\033]133;C\007command output\n\033]133;D;0\007'
printf '\033]52;c;ZmFrZS1jbGlwYm9hcmQ=\007'
printf '\nPress Enter to restore the alternate screen...\n'
read_status=0
IFS= read -r _ || read_status=$?
printf '\n'
printf '\033[0m\033[r'
printf '\033[?1049l'
exit "$read_status"
TERM_SCRIPT
chmod 755 "$fixture_root/run.sh"

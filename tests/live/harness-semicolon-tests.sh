#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
test_root="${TMPDIR:-/tmp}/nmx-harness-semicolon.$$.${RANDOM}"
fake_bin="$test_root/bin"
calls="$fake_bin/calls.log"
mkdir -p "$fake_bin" "$test_root/fixtures"

cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$(dirname -- "$0")/calls.log"
printf '\n' >> "$(dirname -- "$0")/calls.log"
TMUX
chmod +x "$fake_bin/tmux"

PATH="$fake_bin:$PATH" \
  LIVE_BASE_TMPDIR="$test_root/live" \
  LIVE_FIXTURE_ROOT="$test_root/fixtures" \
  "$script_dir/harness" keys L6 C-q ';'

if grep -F 'send-keys -t app:0.0 ' "$calls" | grep -Fq ';'; then
  printf 'semicolon reached tmux as command text\n' >&2
  exit 1
fi

grep -Fq -- 'send-keys -H -t app:0.0 3b' "$calls" || {
  printf 'semicolon was not sent as raw byte 0x3b\n' >&2
  exit 1
}

# Live terminal harness

The live harness runs `nerimux` in a lane-isolated environment and records terminal evidence under `${TMPDIR:-/tmp}/nmx-live/<lane>/`. It uses a private tmux socket for each lane. The examples keep fixture data outside the repository checkout.

Run the commands below from the repository root.

## Requirements

- Nix for the repository build command below.
- Bash, tmux, and `script` for raw terminal capture.
- A built `nerimux` executable. Run `nix build . --no-link --print-out-paths`, then pass the printed output directory or its `bin/nerimux` executable to the harness.
- `jj` for the fixture generators that create repositories and worktrees.

## P0/P1 smoke scope

P0 builds the baseline binary with the Nix command above. The repeatable P1 smoke sequence uses F-bare and covers attach (L1-04), `n` navigation (L2-04), and detach then attach again (L1-10). Run the sequence three times, with `self-check` at the start of each run. The self-check verifies that the public `wait-for` command matches emitted text and times out for absent text.

## Generate a fixture

Each generator accepts an optional output parent and creates its named fixture beneath it. By default, fixtures go under `${TMPDIR:-/tmp}/nmx-live/<lane>/fixtures/`; the output directory uses `default` unless `LIVE_LANE` is set. `LIVE_BASE_TMPDIR` chooses the output base, and `LIVE_LANE` chooses the fixture output directory. `LIVE_LANE` does not select the harness lane; pass the matching lane separately to each harness command. `LIVE_FIXTURE_PARENT` overrides the default, and a positional output parent takes precedence over that variable. Output parents inside the repository are rejected.

```sh
export LIVE_BASE_TMPDIR="${LIVE_BASE_TMPDIR:-${TMPDIR:-/tmp}/nmx-live}"
export LIVE_LANE=L1
tests/live/fixtures/generate-bare.sh
```

With these defaults, the result is available at `$LIVE_BASE_TMPDIR/$LIVE_LANE/fixtures/F-bare`. If `LIVE_FIXTURE_PARENT` is set, the result goes under that parent; a positional output parent takes precedence over both. When using a positional parent with the harness, set `LIVE_FIXTURE_PARENT` to the same parent or set `fixture_parent` to that path in the run block. Generators refuse to replace a non-empty fixture directory. Choose a fresh output parent for another run.

The other generators create these fixtures:

| Generator | Fixture state |
|---|---|
| `generate-dirty.sh` | A repository with modified, added, deleted, untracked, and renamed files, including `-dash`. |
| `generate-behind.sh` | A local bare remote with one local commit ahead and one commit behind. |
| `generate-conflict.sh` | A repository with an unresolved merge conflict. |
| `generate-missing.sh` | Removed, locked, and prunable worktree states. |
| `generate-unreadable.sh` | A checkout with read and search permission removed. |
| `generate-escape.sh` | A symlink from a repository path to a directory outside that repository. |
| `generate-empty.sh` | An empty GHQ root. |
| `generate-scale.sh` | 100 repositories with three worktrees each. |
| `generate-agents.sh` | Fake `claude` and `codex` commands that wait for input and emit terminal control sequences. Set their exit status in `F-agents/bin/exit-code`; `NMX_FAKE_EXIT_CODE` overrides that value when set before `start`. |
| `generate-term.sh` | A script that emits color, alternate-screen, scroll-region, line-drawing, CJK, OSC 133, and OSC 52 output, then waits for Enter before restoring the screen. |
| `generate-clone-src.sh` | A local bare repository used as a clone source. |

Each generator script is named `tests/live/fixtures/generate-<fixture>.sh` and creates `<output-parent>/F-<fixture>/`. Each one refuses to replace a non-empty fixture directory. `generate-unreadable.sh` makes only `checkouts/unreadable` inaccessible; restore it with `chmod u+rwx "$fixture_root/checkouts/unreadable"` before removing that fixture.

## Run a lane

Start the selected binary with a fixture root. Generate F-bare once under the selected fixture parent before running this block. `start` runs the self-check when the lane has no successful self-check marker, before creating or reattaching the app pane. Each check uses an isolated tmux server and retains its evidence under `evidence/self-check/`.

```sh
export LIVE_BASE_TMPDIR="${LIVE_BASE_TMPDIR:-${TMPDIR:-/tmp}/nmx-live}"
export LIVE_LANE=L1
lane_root="$LIVE_BASE_TMPDIR/$LIVE_LANE"
fixture_parent="${LIVE_FIXTURE_PARENT:-$lane_root/fixtures}"
tests/live/harness self-check L1
LIVE_FIXTURE_ROOT="$fixture_parent/F-bare" \
  tests/live/harness start L1 /path/to/nerimux
tests/live/harness wait-for L1 'Repositories' 30
tests/live/harness snap L1 L1-04
tests/live/harness keys L1 n
# This navigation action exercises L2-04 while the same L1 session remains open.
tests/live/harness snap L1 L2-04
tests/live/harness keys L1 C-q d
detach_deadline=$((SECONDS + 10))
until grep -Fq 'nerimux: detached' "$lane_root/evidence/attach-stderr.log"; do
  if (( SECONDS >= detach_deadline )); then
    printf 'timed out waiting for detach\n' >&2
    exit 1
  fi
  sleep 0.1
done
LIVE_FIXTURE_ROOT="$fixture_parent/F-bare" \
  tests/live/harness start L1 /path/to/nerimux
tests/live/harness wait-for L1 'Repositories' 30
tests/live/harness snap L1 L1-10
tests/live/harness stop L1
```

This command set shows one run. For three runs with separate evidence, use a fresh `LIVE_BASE_TMPDIR` and fixture parent for each run, keep `LIVE_LANE=L1`, and generate F-bare once under that run's fixture parent before invoking the block. If `LIVE_FIXTURE_PARENT` is set, choose a fresh value for each run as well. Do not regenerate a non-empty fixture parent. The `LIVE_LANE` value must match the harness lane argument (`L1` here). Set `NERIMUX_BIN` instead of passing the binary argument when several commands use the same build. The value may be an executable path or a build output directory containing `bin/nerimux`.

Run `tests/live/harness self-check <lane>` to repeat the self-check. Every invocation writes a separate evidence directory. `start` accepts lanes `L1` through `L8` and runs the check automatically when `<lane-root>/state/self-check.ok` is absent.

## Run the F-term pane fixture

`raw` captures the `nerimux attach` client itself. To exercise the generated F-term workload inside a pane, use F-bare as the GHQ root and F-term as the fixture root:

```sh
live_root="${TMPDIR:-/tmp}/nmx-live"
fixture_parent="$live_root/L6/fixtures"
tests/live/fixtures/generate-bare.sh "$fixture_parent"
tests/live/fixtures/generate-term.sh "$fixture_parent"
export LIVE_BASE_TMPDIR="$live_root"
export LIVE_FIXTURE_ROOT="$fixture_parent/F-term"
export GHQ_ROOT="$fixture_parent/F-bare/ghq"
tests/live/harness start L6 /path/to/nerimux
tests/live/harness keys L6 C-q t
tests/live/harness keys L6 "bash $LIVE_FIXTURE_ROOT/run.sh" Enter
tests/live/harness wait-for L6 'wide CJK' 30
tests/live/harness snap L6 L6-16
tests/live/harness keys L6 Enter
tests/live/harness stop L6
```

## Harness commands

| Command | Action |
|---|---|
| `start <lane> [binary]` | Start `nerimux attach` in a detached tmux session with the lane directory as its working directory. Mirror client stderr to `evidence/attach-stderr.log`. If the prior client pane exited, respawn it from that directory and attach to the lane's existing server again. |
| `keys <lane> <key>...` | Send keys to the pane and append a UTC timestamp and the keys to `evidence/keys.log`. |
| `wait-for <lane> <regex> <seconds>` | Poll the visible pane until an extended regular expression matches or the timeout expires. |
| `snap <lane> <case-id>` | Save the visible pane with and without SGR sequences under `evidence/snapshots/<case-id>/`. Run `wait-for` first when the expected screen has a unique text marker. Compare snapshots to inspect key-driven changes when that marker is unchanged. |
| `raw <lane> [binary]` | Run the `nerimux attach` client under `script` and save its terminal bytes as `evidence/raw/<lane>.typescript`. Press `C-q` then `d` in that terminal to detach the client. |
| `resize <lane> <columns> <rows>` | Resize the lane's tmux window. |
| `stop <lane> [binary]` | Run `nerimux kill --force`, then stop only that lane's tmux server. |

The harness sets a lane-specific `HOME`, `TMPDIR`, `GHQ_ROOT`, `XDG_STATE_HOME`, `SHELL`, `PATH`, and `TMUX_TMPDIR`. Set `LIVE_BASE_TMPDIR` to change the base directory; it must resolve outside the repository. Set `LIVE_FIXTURE_ROOT` to select a generated fixture; the harness uses its `ghq/` directory as `GHQ_ROOT` unless `GHQ_ROOT` is set explicitly. `start` stores the binary path in the lane state directory, so `stop` reuses it; pass a binary argument or set `NERIMUX_BIN` to select a different one.

The lane directory contains isolated home and state directories, the tmux socket directory, and evidence. The two snapshot files are `pane.txt` and `pane-sgr.ansi`. Raw terminal output is captured separately because tmux pane snapshots do not preserve all terminal control sequences.

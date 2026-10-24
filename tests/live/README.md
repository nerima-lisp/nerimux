# Live terminal harness

The live harness runs `nerimux` in a lane-isolated environment and records terminal evidence under `${TMPDIR:-/tmp}/nmx-live/<lane>/`. It uses a private tmux socket for each lane. The examples keep fixture data outside the repository checkout.

Run the commands below from the repository root.

## Requirements

- Nix for the repository build command below.
- Bash, tmux, and `script` for raw terminal capture.
- A built `nerimux` executable. Run `nix build . --no-link --print-out-paths`, then pass the printed output directory or its `bin/nerimux` executable to the harness.
- `jj` for the fixture generators that create repositories and worktrees.

## Generate a fixture

Each generator accepts one output parent and creates its named fixture beneath it. Use a separate output parent for each lane that runs concurrently.

```sh
lane_root="${TMPDIR:-/tmp}/nmx-live/L1"
tests/live/fixtures/generate-bare.sh "$lane_root/fixtures"
```

The result is available at `$lane_root/fixtures/F-bare`. Generators refuse to replace a non-empty fixture directory. Choose a fresh output parent for another run.

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
| `generate-agents.sh` | Fake `claude` and `codex` commands that wait for input and emit terminal control sequences. |
| `generate-term.sh` | A script that emits color, alternate-screen, scroll-region, line-drawing, CJK, OSC 133, and OSC 52 output. |
| `generate-clone-src.sh` | A local bare repository used as a clone source. |

Each generator script is named `tests/live/fixtures/generate-<fixture>.sh` and creates `<output-parent>/F-<fixture>/`. Each one refuses to replace a non-empty fixture directory.

## Run a lane

Start the selected binary with a fixture root. The first `start` in a lane runs the harness self-check. The self-check proves that `wait-for` finds emitted text and times out for absent text.

```sh
lane_root="${TMPDIR:-/tmp}/nmx-live/L1"
LIVE_FIXTURE_ROOT="$lane_root/fixtures/F-bare" \
  tests/live/harness start L1 /path/to/nerimux
tests/live/harness wait-for L1 'Repositories' 30
tests/live/harness snap L1 L1-04
tests/live/harness keys L1 n
tests/live/harness snap L1 L2-04
tests/live/harness keys L1 C-q d
tests/live/harness wait-for L1 'nerimux: detached' 10
LIVE_FIXTURE_ROOT="$lane_root/fixtures/F-bare" \
  tests/live/harness start L1 /path/to/nerimux
tests/live/harness wait-for L1 'Repositories' 30
tests/live/harness snap L1 L1-10
tests/live/harness stop L1
```

Set `NERIMUX_BIN` instead of passing the binary argument when several commands use the same build. The value may be an executable path or a build output directory containing `bin/nerimux`.

Run `tests/live/harness self-check <lane>` to repeat the self-check. `start` also accepts lanes `L1` through `L8` and runs the check automatically when `<lane-root>/state/self-check.ok` is absent.

## Harness commands

| Command | Action |
|---|---|
| `start <lane> [binary]` | Start `nerimux attach` in a detached tmux session, or reattach when the previous app pane has exited. |
| `keys <lane> <key>...` | Send keys to the pane and append a UTC timestamp and the keys to `evidence/keys.log`. |
| `wait-for <lane> <regex> <seconds>` | Poll the visible pane until an extended regular expression matches or the timeout expires. |
| `snap <lane> <case-id>` | Save the visible pane with and without SGR sequences under `evidence/snapshots/<case-id>/`. Run `wait-for` first when the expected screen has a unique text marker. Compare snapshots to inspect key-driven changes when that marker is unchanged. |
| `raw <lane> [binary]` | Run the client under `script` and save its terminal bytes as `evidence/raw/<lane>.typescript`. Press `C-q` then `d` in that terminal to detach the client. |
| `resize <lane> <columns> <rows>` | Resize the lane's tmux window. |
| `stop <lane> [binary]` | Run `nerimux kill --force`, then stop only that lane's tmux server. |

The harness sets a lane-specific `HOME`, `TMPDIR`, `GHQ_ROOT`, `XDG_STATE_HOME`, `SHELL`, `PATH`, and `TMUX_TMPDIR`. Set `LIVE_BASE_TMPDIR` to change the base directory. Set `LIVE_FIXTURE_ROOT` to select a generated fixture; the harness uses its `ghq/` directory as `GHQ_ROOT` unless `GHQ_ROOT` is set explicitly. `start` stores the binary path in the lane state directory, so `stop` reuses it; pass a binary argument or set `NERIMUX_BIN` to select a different one.

The lane directory contains isolated home and state directories, the tmux socket directory, and evidence. The two snapshot files are `pane.txt` and `pane-sgr.ansi`. Raw terminal output is captured separately because tmux pane snapshots do not preserve all terminal control sequences.

# Getting started

## Install and run

Nix is the only supported build path: it pins SBCL and every Lisp dependency,
so a build either reproduces exactly or fails loudly.

```bash
nix run github:nerima-lisp/nerimux -- attach
```

From a checkout:

```bash
nix build .                           # → ./result/bin/nerimux
./result/bin/nerimux attach
```

## Usage

```bash
nerimux attach                         # open the workspace overview
nerimux attach organization/repository # focus a repository/worktree
nerimux attach /path/to/worktree       # open a local worktree
```

`attach` auto-starts the headless runtime and connects a thin client. A selector
containing a slash is resolved as an organization/repository selector or a
local worktree path. `attach` and `server` are the only commands; anything
else — including `nerimux` with no arguments — prints the usage summary and
exits non-zero. `-V`/`-h` are the only global flags.

If `attach` has to auto-start the server and something goes wrong, the
spawned server's stdout/stderr are captured to a per-session-name log file
rather than discarded, so a crash leaves a forensic trail. The path is
`nerimux/<name>.log` under a state-home directory resolved as `$XDG_STATE_HOME`
(falling back to `~/.local/state`), or under `$NERIMUX_RUNTIME_STATE` when
that's set — the same state-home resolution the runtime-state snapshot file
uses, so the two files always land in the same directory but never collide.
The log directory is created `0700`. See `%runtime-log-path` and
`%runtime-state-home` in `src/bootstrap/runtime-lifecycle.lisp`.

## Default key bindings

The workspace UI uses **`C-q`** as its prefix. The initial view is the overview;
`C-p` opens the global picker across organizations, repositories, worktrees, and
panes.

| Key | Action |
|---|---|
| `C-q d` | Detach while keeping the runtime session resident |
| `C-p` | Open the global picker |
| `o` / `d` / `a` | Overview / detail / attention view |
| `j` / `k` / arrows | Move the selection |
| `Enter` | Focus the selected worktree, pane, or attention item |
| `r` | Refresh the workspace catalog and VCS state |
| `i` / `c` / `:` | Input / copy / command mode |
| `Esc` | Close or cancel the active modal or mode |

The tmux keystroke pipeline (prefix bindings, `bind`/`unbind`) and the tmux
command surface are gone, as is the event-hook registry; see
[Compatibility](reference/compatibility.md)
for what changed. nerimux still parses `.tmux.conf` syntax at startup — see
[Configuration](guide/configuration.md) for what a config file can do today.

## Development

```bash
nix develop                      # SBCL with every dependency on the registry
sbcl --script run-tests.lisp     # the full suite, exactly as CI runs it
nix flake check --print-build-logs   # build + every checks.* derivation
nix fmt                          # treefmt (nixfmt)
```

Inside `nix develop`, `nerimux-sbcl` wraps an `sbcl` invocation with ASDF and
the sibling-library registry already set up:

```bash
nerimux-sbcl --eval '(asdf:load-system "nerimux")' --eval '(nerimux:main)'
nerimux-coverage ./coverage-report    # sb-cover report via cl-weave
```

## Testing

`nix flake check` runs three derivations in parallel:

| Check | What it covers |
|---|---|
| `default` | the full unit + integration suite (`nerimux/test`) |
| `formatting` | treefmt / nixfmt over every tracked Nix file |
| `docs` | this site, built with `mkdocs --strict` |

The main suite (`find t -name '*.lisp' | wc -l` for today's file count) runs on
[cl-weave](https://github.com/nerima-lisp/cl-weave) and covers the VT100
emulator, layout geometry, command dispatch, format engine, options,
copy mode, the client/server protocol, and live PTY integration against a real
shell. PTY tests self-skip where `/dev/ptmx` is unavailable, so sandboxed runs
stay meaningful. The runner is deliberately sequential — tests share global
session/socket/PTY state.

There is also an end-to-end smoke test that drives the real binary inside a
PTY. It is deliberately kept out of the ASDF test system:

```bash
nix build .
sbcl --no-sysinit --no-userinit --script t/e2e/e2e-smoke.lisp result/bin/nerimux
```

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

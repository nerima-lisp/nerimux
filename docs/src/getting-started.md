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
nerimux attach github.com/org/repo     # focus a repository by its ghq spec
nerimux attach /path/to/worktree       # open a local worktree
nerimux kill                           # stop the server (--force closes panes)
```

`attach` auto-starts the headless runtime and connects a thin client. A selector
containing a slash is resolved as a repository selector — the full ghq
specification, `host/organization/repository` — or a local worktree path; a
selector that matches both readings at once opens the global picker with the
selector pre-typed instead of guessing. `attach`, `server`, and `kill` are the
only commands; anything else — including `nerimux` with no arguments — prints
the usage summary and exits non-zero. `-V`/`-h` are the only global flags.

The overview tree appears as soon as the repository scan finishes; the
per-repository VCS status (dirty/ahead/behind flags) streams in afterwards,
since it runs `git status` across every repository. A repository the scan
cannot read — a broken or half-deleted clone in the root — is kept in the
tree flagged `!` rather than aborting the scan.

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
| `o` / `d` | Overview / detail view |
| `j` / `k` / `h` / `l` | Move the selection |
| `Enter` | Expand or collapse an organization or repository; focus a worktree, window, or pane |
| `r` | Refresh the workspace catalog and VCS state |
| `i` / `c` / `:` | Input / copy / command mode |
| `Esc` | Close or cancel the active modal or mode |

The tree opens showing organizations only; `Enter` opens one level at a time.
`Enter` on a worktree returns to the pane you last had there, or starts one if
you never opened it.

Inside the picker, every printable key is a character of the search query, so
the selection moves with **`C-p`** and **`C-n`** rather than `j` and `k`.
`C-r` toggles regex matching, `Enter` selects, `Esc` closes.

The tmux keystroke pipeline (prefix bindings, `bind`/`unbind`) and the tmux
command surface are gone. nerimux reads no configuration file; every key
binding and layout value above is a compiled-in constant.

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
emulator, layout geometry, copy mode, and the client/server protocol. The
runner is deliberately sequential — tests share global session/socket state.

Live PTY integration against a real shell is a separate system,
`nerimux/pty-test`, run with `nix run .#test-pty`. It was split out of the
main suite (R9.2) so that `nix flake check` never reports a pass for PTY
work it silently skipped in a sandbox without `/dev/ptmx`; run it yourself
when touching PTY code, because the flake gate does not.

There is also an end-to-end smoke script, `t/e2e/e2e-smoke.lisp`, kept out of
the ASDF test system because it needs a built binary and a real `/dev/ptmx`.
It currently predates the workspace-only entry surface: it launches the bare
binary as the PTY's shell (relying on the removed standalone mode) and detaches
with the removed `C-b` prefix, so it does not pass against today's binary and
needs a rewrite around `attach`/`C-q d` before it is usable again.

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

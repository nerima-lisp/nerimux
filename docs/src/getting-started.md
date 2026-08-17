# Getting started

## Install and run

Nix is the only supported build path: it pins SBCL and every Lisp dependency,
so a build either reproduces exactly or fails loudly.

```bash
nix run github:nerima-lisp/cl-tmux -- attach
```

From a checkout:

```bash
nix build .                           # → ./result/bin/cl-tmux
./result/bin/cl-tmux attach
```

## Usage

```bash
cl-tmux attach                         # open the workspace overview
cl-tmux attach organization/repository # focus a repository/worktree
cl-tmux attach /path/to/worktree       # open a local worktree
```

`attach` auto-starts the headless runtime and connects a thin client. A selector
containing a slash is resolved as an organization/repository selector or a
local worktree path. Running `cl-tmux` with no command remains the standalone
compatibility entry point. Socket selection works like tmux: `-L <name>` picks a named socket in the
per-user directory (created `0700` under `$TMUX_TMPDIR`, falling back to the
system temp dir), and `-S <path>` uses an explicit path.

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

The compatibility server/client commands and tmux-style bindings remain
available for existing workflows. See [Compatibility](reference/compatibility.md)
for that command surface and [Configuration](guide/configuration.md) for
configuration details.

## Development

```bash
nix develop                      # SBCL with every dependency on the registry
sbcl --script run-tests.lisp     # the full suite, exactly as CI runs it
nix flake check --print-build-logs   # build + every checks.* derivation
nix fmt                          # treefmt (nixfmt)
```

Inside `nix develop`, `cl-tmux-sbcl` wraps an `sbcl` invocation with ASDF and
the sibling-library registry already set up:

```bash
cl-tmux-sbcl --eval '(asdf:load-system "cl-tmux")' --eval '(cl-tmux:main)'
cl-tmux-coverage ./coverage-report    # sb-cover report via cl-weave
```

## Testing

`nix flake check` runs five derivations in parallel:

| Check | What it covers |
|---|---|
| `default` | the full unit + integration suite (`cl-tmux/test`) |
| `weave` | the cl-prolog reasoning read-model (`cl-tmux/weave`) |
| `dataflow` | the copy-mode lifecycle read-model (`cl-tmux/dataflow`) |
| `formatting` | treefmt / nixfmt over every tracked Nix file |
| `docs` | this site, built with `mkdocs --strict` |

The main suite (290+ test files, 11,000+ checks) runs on
[cl-weave](https://github.com/nerima-lisp/cl-weave) and covers the VT100
emulator, layout geometry, command dispatch, format engine, options/hooks,
copy mode, the client/server protocol, and live PTY integration against a real
shell. PTY tests self-skip where `/dev/ptmx` is unavailable, so sandboxed runs
stay meaningful. The runner is deliberately sequential — tests share global
session/socket/PTY state.

To run a single suite by hand:

```bash
CL_TMUX_TEST_SYSTEM=cl-tmux/weave sbcl --script run-tests.lisp
```

There is also an end-to-end smoke test that drives the real binary inside a
PTY. It is deliberately kept out of the ASDF test system:

```bash
nix build .
sbcl --no-sysinit --no-userinit --script t/e2e/e2e-smoke.lisp result/bin/cl-tmux
```

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

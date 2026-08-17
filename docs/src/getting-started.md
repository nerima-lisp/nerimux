# Getting started

## Install and run

Nix is the only supported build path: it pins SBCL and every Lisp dependency,
so a build either reproduces exactly or fails loudly.

```bash
nix run github:nerima-lisp/cl-tmux    # run directly
```

From a checkout:

```bash
nix build .                           # → ./result/bin/cl-tmux
./result/bin/cl-tmux
```

## Usage

```bash
cl-tmux                          # standalone session (no server)
cl-tmux new-session -s work      # create session "work" on the server
cl-tmux attach -t work           # attach; C-b d detaches, server keeps running
cl-tmux attach -t work -r        # read-only attach
cl-tmux list-sessions            # what's running
cl-tmux kill-server              # stop everything
cl-tmux -C                       # control mode (text protocol on stdin/stdout)
cl-tmux -V                       # print version; --help prints a usage summary
```

Socket selection works like tmux: `-L <name>` picks a named socket in the
per-user directory (created `0700` under `$TMUX_TMPDIR`, falling back to the
system temp dir), and `-S <path>` uses an explicit path.

## Default key bindings

The prefix is **`C-b`**. Common defaults (see `C-b ?` / `list-keys` for the
full table, including `-N` notes):

| Key | Action |
|---|---|
| `c` / `n` / `p` / digits | New / next / previous / select window |
| `"` / `%` | Split pane horizontally / vertically |
| `o`, arrow keys | Move between panes |
| `C-arrows` / `M-arrows` | Resize pane by 1 / 5 (repeatable) |
| `[` / `]` | Enter copy mode / paste buffer |
| `x` / `&` | Kill pane / window (with confirmation) |
| `,` / `$` | Rename window / session |
| `d` | Detach |

All bindings are re-bindable with `bind-key` / `unbind-key`, in the config file
or at the command prompt, including custom key tables. See
[Configuration](guide/configuration.md).

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
| `weave` | the cl-prolog-kit reasoning read-model (`cl-tmux/weave`) |
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

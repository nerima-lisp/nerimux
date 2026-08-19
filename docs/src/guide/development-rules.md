# Project-specific development rules

The organization-wide contribution guide lives in
[nerima-lisp/.github](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md).
This page records only the rules specific to nerimux — the ones that are easy
to trip over and that no general guide would mention.

## The flake only sees git-tracked files

`nix build` and `nix flake check` copy the *git tree*, not the working
directory. If you add a new source file — including any file pulled in by a
loader `load` form — you must `git add` it before the Nix build can see it, or
you get a confusing "file not found" failure.

## Tests must not leak global state

Tests that bind keys, set options, or install hooks must wrap themselves in the
isolation helpers (`with-isolated-config`, `with-isolated-hooks`, …) from
`t/helpers-*.lisp`. Otherwise they clobber the default bindings for every test
that runs after them.

## The suite runs sequentially by design

This is not a performance choice. Integration suites share global session,
runtime, socket and PTY state, and the PTY tests fork real shells; a parallel
runner corrupts forked-child state and leaks reader threads. `run-tests.lisp`
drives `cl-weave:run-all` with `:max-workers 1`. Do not parallelize it.

Each test that spawns a background thread or server joins it itself (see
`with-loop-state` in `t/helpers-loop-fixtures.lisp`), so isolation does not
depend on suite boundaries or execution order.

PTY tests self-skip when `/dev/ptmx` is unavailable — for example inside the
Nix sandbox on some platforms — so a sandboxed check run is still meaningful.

## Behavior changes need a tmux reference

nerimux aims for behavioral parity with tmux. When changing or adding
command/format/escape behavior, state in the pull request what tmux does — man
page section, upstream source, or a transcript from a real tmux session — and
add a regression test that pins it.

## Check existing tests before flipping behavior

Some tests deliberately pin the *absence* of a feature. If your change makes
such a test fail, flip the test in the same commit and explain why in the
message.

## Keep the data/logic layering

`src/` follows a layered layout (`domain` / `application` / `infrastructure` /
`presentation` / `bootstrap`), described in
[Architecture](../reference/architecture.md). Terminal code further separates
data structs (`types`) from logic (`actions`, `csi`, `sgr`). New code should
land in the matching layer, and new public accessors must also be re-exported
from the umbrella packages in `src/bootstrap/package*.lisp`.

## Reporting bugs

Include:

1. What you ran — command line, config file, and the byte/escape sequence if it
   is an emulation bug.
2. What tmux does in the same situation.
3. What nerimux does instead.

A failing cl-weave test case is the ideal bug report.

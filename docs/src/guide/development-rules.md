# Project-specific development rules

The organization-wide contribution guide lives in
[nerima-lisp/.github](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md).
This page records only the rules specific to nerimux — the ones that are easy
to trip over and that no general guide would mention.

## When the suite starts and then stops dead

`nix run .#test` printing `Running test system nerimux/test` and then producing
nothing — no output, no error, no CPU — is almost never the suite. Check the
machine before you check the code:

```bash
vm_stat | head -4          # "Pages free" in the low thousands means no free RAM
sysctl vm.swapusage        # used ≈ total means the swap file is full too
ps -eo %cpu,command -r | head -5
```

Memory exhaustion is one cause, and the cheap one to rule out. It is not the
only one: the same symptom has been seen on macOS/arm64 with the machine idle
and gigabytes free. In that form it stops before any code in this repository is
read — looking up the first sibling system is enough — every available SBCL
version reproduces it, and the stopping point moves between runs. The cause is
not known. What matters here is that none of it is evidence about the tests.

If you retry, run `sbcl --script run-tests.lisp` from a fixed directory rather
than `nix run .#test`, which copies the tree to a new temporary directory each
time. ASDF's output paths follow the source path, so a retry through the app
recompiles from nothing while a retry from a fixed directory resumes.

Two measurement traps make this hard to see. `ps` reports `%cpu` as a lifetime
average, so a process that ran for a moment and then stopped forever reads as
`0.0` and looks idle rather than stuck — the cumulative `time` column is what
settles it. And `sample` cannot walk SBCL's Lisp stack, so the main thread shows
as a single unresolvable frame no matter where it is.

The static checks in `scripts/checks/` are what remains available when this
happens. They are not a substitute for the suite and do not claim to be.

## Three failures the suite cannot report

A test suite reports on tests that ran. It says nothing when it could not load —
and the three ways this tree stops loading all look like silence rather than a
red test:

- a file that no longer reads (a deleted line took a parent form's closing paren
  with it);
- a manifest entry with no file behind it (ASDF aborts, and *every* test
  disappears at once), or a file with no manifest entry (it is simply never
  loaded, and its tests quietly stop running);
- a `PKG:SYM` reference to a symbol `PKG` does not export, which is a *read-time*
  error, so the file is unreadable rather than merely broken.

`scripts/checks/` covers all three without ASDF and without a compile. Run them
before you trust a green, and especially before you trust a green after a
deletion. See that directory's README for what each one does and does not cover.

## The flake only sees git-tracked files

`nix build` and `nix flake check` copy the *git tree*, not the working
directory. If you add a new source file — including any file pulled in by a
loader `load` form — you must `git add` it before the Nix build can see it, or
you get a confusing "file not found" failure.

## Tests must not leak global state

Tests that mutate a special variable the runtime reads — the session registry,
the dirty flag, the running flag — must wrap themselves in the isolation helpers
in `t/helpers-*.lisp`. Otherwise they clobber that state for every test after
them.

There used to be more of these helpers than there are now: the ones that
isolated the option store, the config directives, and the hook registry went
with the machinery they isolated. There is no configuration to leak anymore.

## CI gates Linux; macOS is checked by hand

`.github/workflows/ci.yml` runs `nix flake check` on `ubuntu-latest`, and that
is the gate a pull request has to pass. The flake defines the same checks for
`aarch64-darwin`, but nothing runs them automatically — a development machine
cannot cross-build the Linux side without a remote builder, so `nix flake check`
on a Mac only ever exercises the Darwin attributes.

The practical rule: run `nix flake check` locally before pushing, and say which
platform you ran it on when you report a green. A green on one is not a green on
the other.

## The real-PTY suite is a separate system

`nerimux/test` spawns no pseudo-terminal. Every case that forks a shell under a
PTY lives in `nerimux/pty-test` and runs through `nix run .#test-pty`.

It is an app, not a check, on purpose. A check builds in a sandbox with no
`/dev/ptmx`, so those cases would hit their skip guard and be counted as passes —
one number covering both "the logic is right" and "the PTY integration works",
with only the first ever true. Adding it to `checks` would restore exactly the
false green the split removed.

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

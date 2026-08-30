# Project-specific development rules

The organization-wide contribution guide lives in
[nerima-lisp/.github](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md).
This page records only the rules specific to nerimux — the ones that are easy
to trip over and that no general guide would mention.

## When the suite starts and then stops dead

`nix run .#test` printing `Running test system nerimux/test` and then producing
nothing — no output, no error, no CPU — has been seen on macOS/arm64, and it is
not the suite. Garbage collection deadlocks. Check for it before reading a line
of Lisp:

```lisp
;; sbcl --script this-file
(let (l) (dotimes (i 5000000) (push i l)) (length l))   ; ~80 MB
(format t "~&GC survived~%")
```

On an affected machine that never prints, with the process at zero CPU and
unkillable by `sb-ext:with-timeout` — the block is below Lisp, and every thread
is parked at a stop-the-world safepoint.

What the size sweep shows is that the *first* collection is the one that dies;
the heap only decides when it fires:

| dynamic space | allocated | result |
|---|---|---|
| 1 GB (default) | 80 MB | deadlock |
| 16 GB | 80 MB | fine |
| 16 GB | 1 GB | deadlock |

Work that stays under the threshold finishes: the checks in `scripts/checks/`,
loading a system, running a handful of suites. Work that crosses it stops
wherever it happens to be, which is why raising the heap looks like progress
without fixing anything.

That accounts for a lot, but not for all of it, and the difference matters.
Running the whole suite still stops with collection effectively disabled —
`(setf (sb-ext:bytes-consed-between-gcs) (* 50 1024 1024 1024))` under a 64 GB
heap, 292 MB consed, `sb-ext:*after-gc-hooks*` never fired. Loading the system
completes; `cl-weave:run-all` over the full tree then blocks with no collection
having run. So there is a second stall here that the collector does not explain,
and it has not been identified.

Nothing in this repository can work around either, and nothing here should be
changed in response to them.

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
in `tests/helpers-*.lisp`. Otherwise they clobber that state for every test after
them.

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

When iterating on one area, set `CL_WEAVE_TEST_FILTER` to a
case-insensitive substring of the cl-weave test path:

```sh
CL_WEAVE_TEST_FILTER=renderer nix run .#test
```

Each test that spawns a background thread or server joins it itself (see
`with-loop-state` in `tests/helpers-loop-fixtures.lisp`), so isolation does not
depend on suite boundaries or execution order.

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
from its unit's own `packages/<name>/src/package.lisp`.

## Two timeout vocabularies, and which takes which

The codebase bounds waits with two different macros, and they do **not** take
the same kind of deadline. Passing the wrong one is silent, not a type error.

`cl-concurrent-kit:with-timeout` takes a `cl-date-kit:DURATION`. Construct it
with `cl-date-kit:duration-of-millis` or `cl-date-kit:duration-of-seconds`,
never a bare number. It signals `cl-concurrent-kit:operation-timed-out`, which
**is** an `error`, so an ordinary `(error ...)` clause catches it.

`sb-ext:with-timeout` takes **bare seconds**. `+send-frame-timeout-seconds+`
and `+pty-write-timeout-seconds+` are both plain integers for that reason. It
signals `sb-ext:timeout`, which is a `serious-condition` and deliberately
**not** an `error` — so an `(error ...)` clause silently misses it and the
condition escapes. On a non-main thread that is fatal to the whole process,
not just the thread. Use the `peer-io-failure` type (`src/runtime.lisp`),
which is `(or error sb-ext:timeout)`, wherever you contain either one.

Prefer bounding a wait at all over picking the prettier vocabulary: an
unbounded wait on the serve-loop thread hangs every attached client.

## Reporting bugs

Include:

1. What you ran — command line and the byte/escape sequence if it is an
   emulation bug. There is no config file to include; nerimux reads none.
2. What tmux does in the same situation.
3. What nerimux does instead.

A failing cl-weave test case is the ideal bug report.

# Benchmarks

This page records measured numbers. It exists because
`PERFORMANCE_STANDARD.md` names nerimux as one of the packages whose runtime is
dominated by caller-sized input, and because nerimux is one of two repositories
expected to miss the organization-wide `nix flake check` target. Without a
recorded baseline there is no way to tell whether a change made things slower.

No performance adjective anywhere in this repository's documentation is allowed
without a link to a number on this page.

## `nix flake check` runtime

**Target**: 5 minutes. **Cap**: 10 minutes. nerimux is recorded as the
larger of the two expected exceptions. For today's size, run
`find t -name '*.lisp' | wc -l` and `wc -l` over the same set — the figure moved
sharply during the workspace-only conversion and a number written here goes
stale faster than it is read.

Measured on the development machine (aarch64-darwin, Apple silicon), with the
sibling libraries and nixpkgs dependencies already in the local store, so the
figures cover nerimux's own derivations only:

| Date | Scope | Wall clock |
|---|---|---|
| 2026-07-26 | `nix flake check` before the migration — 3 checks (`default`, `weave`, `dataflow`), all rebuilt | 157 s |
| 2026-07-26 | `nix flake check` after the migration — 5 checks, with `default`, `weave`, `dataflow` and `formatting` rebuilt and `docs` cached | 78 s |

Both runs build the test derivations from scratch; only the dependency closure
is shared. The `docs` derivation is a `mkdocs build` of the pages listed in
`docs/mkdocs.yml`'s nav and is
noise at this scale.

Suite sizes at that second measurement: `default` 4277 cases (4276 passed, 1
skipped), `weave` 26, `dataflow` 17. **Every row above is stale, and the shape of
the table has changed underneath them.** The workspace-only conversion deleted
the tmux command table, the keystroke pipeline and the config key-table store
along with their tests, and the `weave` check no longer exists at all — the
`nerimux/reasoning` system it covered was retired with the key-table store it
projected. `nix flake check` now runs four derivations, not five. `dataflow` is
unchanged at 17; the `default` count has moved with every deletion pass, so read
it from `nix build .#checks.<system>.default` rather than from here. The
wall-clock rows have not been re-measured against the smaller tree — they
describe a 2026-07-26 configuration with substantially more test code, and should
not be quoted as current.

## Shipped core image size

The workspace-only conversion removed 95 source files (the tmux command table,
the keystroke pipeline, control mode, the standalone entry point). The obvious
question is how much that took off the shipped `nerimux.core`.

**It is not currently answerable to the precision this page once claimed.**
`nix build .#nerimux --rebuild` makes Nix's own determinism check fire: building
the *same, unchanged* source twice does not reproduce a byte-identical
`nerimux.core`. The build ends in
`save-lisp-and-die ... :compression t`, and the compressed size of an SBCL core
is sensitive to heap layout — symbol and hash-table ordering, gensym counters —
not only to how much source went in.

Observed spread between builds of identical source was on the order of 10^5
bytes, which is the same magnitude as the deltas that were being attributed to
code removal. A single `stat` per side therefore cannot support a figure like
"800,016 bytes smaller", and that claim has been withdrawn rather than restated
with a different number.

To make this measurable: take several `--rebuild` samples per side, establish
the noise floor, and quote a figure only if the difference clears it. Until then
this page records no core-size delta for the workspace-only conversion.

### Result

The suite comes in **under the 5-minute target** on this machine, which is a
better outcome than `PERFORMANCE_STANDARD.md` anticipated when it recorded
nerimux as an exception on test-suite size alone. Two things explain the gap
between size and runtime:

- The three test derivations are independent, so `nix flake check` builds them
  in parallel rather than serially. This is the concrete payoff of expressing
  granularity as `checks.*` instead of as separate CI jobs.
- The suite is dominated by in-process unit tests. The slow parts — PTY and
  socket integration — self-skip where `/dev/ptmx` is unavailable, and are a
  small fraction of the file count.

The 157 s → 78 s drop between the two rows is not an optimization. The first
row was measured on a colder store, and the second reuses more of the
dependency closure. Do not read it as a speedup; the honest claim is only that
both figures are under the target.

The exception should stay recorded until the same measurement exists for the
`x86_64-linux` CI runner, which is slower and has a cold store on most runs.
The GitHub Actions job carries `timeout-minutes: 30` to leave room for a
fully cold build.

### How to reproduce

```bash
cd nerimux
time nix flake check --print-build-logs
```

For a single suite:

```bash
time nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).default
```

## The one enforced budget, and how it is measured

`renderer-suite/tui-kit > keeps the mandatory overview scale within the initial
and scroll budgets` is the only performance figure this repository *enforces*.
It renders the mandatory workspace scale (1000 organizations, 1000 repositories,
5000 worktrees, 5000 panes) and requires both the initial frame and a
fully-scrolled frame under **100 ms**.

How that figure is produced matters, and was wrong for a long time. It used to
be a single `get-internal-real-time` sample per frame with no warm-up. On a
shared machine that measures machine availability as much as render cost: the
same binary on the same tree measured **67–75 ms idle and 102–112 ms under
load**, so the check inverted depending on what else was running. It failed
repeatedly against changes that could not have affected rendering.

`benchmark-workspace-overview` now discards a warm-up render of each frame and
reports the **median of five measured runs**. The 100 ms requirement is
unchanged — only the estimator is. This removes single-sample noise; it does not
make the check immune to a saturated machine, and nothing can. If it goes red,
check `uptime` first: on a 16-core machine a 1-minute load average above about
10 puts the render over budget on its own.

## Not yet measured

`PERFORMANCE_STANDARD.md` also asks for a startup-time measurement, because
nerimux saves a compressed core (`:compression t`) and a terminal multiplexer
sits where a human waits for it. That measurement does not exist yet and is
not claimed anywhere.

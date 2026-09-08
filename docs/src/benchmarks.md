# Benchmarks

This page records measured numbers. It exists because
`PERFORMANCE_STANDARD.md` names nerimux as one of the packages whose runtime is
dominated by caller-sized input. Without a recorded baseline there is no way to
tell whether a change made things slower.

No performance adjective anywhere in this repository's documentation is allowed
without a link to a number on this page.

## `nix flake check` runtime

**Target**: 5 minutes. **Cap**: 10 minutes. Run
`nix flake check --print-build-logs` for the current check graph; source and
test counts are intentionally not duplicated in this historical page.

Measured on the development machine (aarch64-darwin, Apple silicon), with the
sibling libraries and nixpkgs dependencies already in the local store, so the
figures cover nerimux's own derivations only:

| Date | Scope | Wall clock |
|---|---|---|
| 2026-07-26 | `nix flake check` before the migration — 3 checks (`default`, `weave`, `dataflow`), all rebuilt | 157 s |
| 2026-07-26 | `nix flake check` after the migration — 5 checks, with `default`, `weave`, `dataflow` and `formatting` rebuilt and `docs` cached | 78 s |

These are historical snapshots of the pre-workspace-only check graph.

Both runs build the test derivations from scratch; only the dependency closure
is shared. The `docs` derivation is a `mkdocs build` of the pages listed in
`docs/mkdocs.yml`'s nav and is
noise at this scale.

The workspace-only conversion changed the check graph after both snapshots.
The current flake exposes one Lisp test derivation, `default`, plus the
`formatting` and `docs` checks. The `weave` and `dataflow` checks in the table
are historical names; they are not current entry points. The wall-clock rows
have not been re-measured against the current tree and must not be quoted as
current.

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

The recorded snapshots are both **under the 5-minute target** on the machine
where they were measured. They do not establish the current runtime. The
current check graph has one Lisp test derivation plus formatting and docs; the
host-side PTY check is a separate app and is not part of `nix flake check`.
The in-process suite remains the appropriate place for hermetic regression
coverage, while PTY behavior needs a host check.

The 157 s → 78 s drop between the two rows is not an optimization. The first
row was measured on a colder store, and the second reuses more of the
dependency closure. Do not read it as a speedup; the honest claim is only that
both historical figures are under the target.

### How to reproduce

```bash
time nix flake check --print-build-logs
```

For a single suite:

```bash
time nix build .#checks.$(nix eval --raw --impure --expr builtins.currentSystem).default
```

## Attach first-frame latency (NFR-2)

The measurement uses the PTY path from `tests/e2e/attach-scenario.lisp`. Each
sample starts a fresh 24x80 PTY in an isolated environment and records the
monotonic time from just before `forkpty-with-shell` launches `attach` until
the first non-empty PTY output. A matching `printf` control run measures PTY
and shell startup noise. The five control samples' max-minus-min range is the
noise floor; the larger range across the two revisions is used for the
comparison. The benchmark driver is
`tests/e2e/benchmark-first-frame.lisp`.

Measured on 2026-09-08, `aarch64-darwin`. The quiet-state check found no
running SBCL, Nix build/run/flake, test, or e2e process. The 1-minute load
average was 14.61 on a 16-CPU host at the start of the run; the 5- and
15-minute averages were higher, so the control range is retained in the
interpretation.

| Revision | Control samples (ms) | Control median | Attach samples (ms) | Attach median |
|---|---|---:|---|---:|
| Before Phase 1, `b6960917a8ba95f60be40a5811e227daa72ef46f` | 89.772, 72.541, 77.574, 73.072, 83.599 | 77.574 | 125.712, 85.924, 89.115, 88.926, 97.674 | 89.115 |
| Phase 3 candidate, `e48d01e5d894ab9271d8b95edaa711aeb45b3237` | 82.169, 96.803, 76.304, 109.280, 97.855 | 96.803 | 143.556, 124.048, 131.569, 131.448, 107.608 | 131.448 |

The control ranges are 17.231 ms before Phase 1 and 32.976 ms for the Phase 3
candidate, so the recorded noise floor is 32.976 ms. The raw attach median
delta is **+42.333 ms**, which exceeds that floor and is recorded as an
observed regression in this run. After subtracting each revision's control
median, the delta is **+23.104 ms**, below the floor; the run therefore cannot
attribute the whole raw delta to the Phase 1 changes. This is not evidence for
a regression-free claim, and it should be repeated on a quieter host before
using it as a release performance baseline.

To reproduce one side, run the following twice with `control` and `attach`,
using the checkout and built binary for that revision:

```bash
nix develop --command sbcl --dynamic-space-size 4096 \
  --no-sysinit --no-userinit --disable-debugger \
  --script tests/e2e/benchmark-first-frame.lisp . /path/to/nerimux control
nix develop --command sbcl --dynamic-space-size 4096 \
  --no-sysinit --no-userinit --disable-debugger \
  --script tests/e2e/benchmark-first-frame.lisp . /path/to/nerimux attach
```

The driver emits five samples for each mode. The benchmark binaries used for
the recorded run were the Nix outputs built from the two revisions above.

## Other measurements

`PERFORMANCE_STANDARD.md` also asks for a startup-time measurement, because
nerimux saves a compressed core (`:compression t`) and a terminal multiplexer
sits where a human waits for it. That measurement does not exist yet and is
not claimed anywhere.

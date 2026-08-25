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

## Workspace-overview render cost (measured, not enforced)

`benchmark-workspace-overview` (`t/helpers-renderer-benchmark.lisp`) measures
frame cost at the mandatory workspace scale (1000 organizations, 1000
repositories, 5000 worktrees, 5000 panes): both the initial frame and a
fully-scrolled frame.

This used to back a test asserting a **100 ms** budget on that figure. The
assertion is gone. It used to be a single `get-internal-real-time` sample per
frame with no warm-up — on a shared machine that measures machine
availability as much as render cost: the same binary on the same tree
measured **67–75 ms idle and 102–112 ms under load**, so the check inverted
depending on what else was running, and failed repeatedly against changes
that could not have affected rendering. The measurement itself is still
useful when someone is deliberately looking at render cost, so it was kept —
moved out of the product package and off any regression gate. Nothing calls
it and no test checks its output.

Run it by hand from a REPL with the test system loaded:

```lisp
(nerimux/test::benchmark-workspace-overview)
(nerimux/test::benchmark-workspace-overview :organization-count 100 :samples 9)
```

It discards a warm-up render of each frame and reports the median of five
measured runs by default, which removes single-sample noise without making
the number immune to a saturated machine.

## Not yet measured

`PERFORMANCE_STANDARD.md` also asks for a startup-time measurement, because
nerimux saves a compressed core (`:compression t`) and a terminal multiplexer
sits where a human waits for it. That measurement does not exist yet and is
not claimed anywhere.

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
larger of the two expected exceptions, with 304 test files and roughly 52,000
lines of test code.

Measured on the development machine (aarch64-darwin, Apple silicon), with the
sibling libraries and nixpkgs dependencies already in the local store, so the
figures cover nerimux's own derivations only:

| Date | Scope | Wall clock |
|---|---|---|
| 2026-07-26 | `nix flake check` before the migration — 3 checks (`default`, `weave`, `dataflow`), all rebuilt | 157 s |
| 2026-07-26 | `nix flake check` after the migration — 5 checks, with `default`, `weave`, `dataflow` and `formatting` rebuilt and `docs` cached | 78 s |

Both runs build the test derivations from scratch; only the dependency closure
is shared. The `docs` derivation is a `mkdocs build` of eight pages and is
noise at this scale.

Suite sizes at the second measurement: `default` 4277 cases (4276 passed, 1
skipped), `weave` 26, `dataflow` 17.

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

## Not yet measured

`PERFORMANCE_STANDARD.md` also asks for a startup-time measurement, because
nerimux saves a compressed core (`:compression t`) and a terminal multiplexer
sits where a human waits for it. That measurement does not exist yet and is
not claimed anywhere.

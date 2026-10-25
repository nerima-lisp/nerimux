# P0 foundation baseline

This note records the baseline evidence used by the foundation refactor. It
separates measurements from checks that were unavailable on the development
machine.

## Static baseline

- The manifest contains 247 test files, and the on-disk `t/` tree contains 247
  files. `scripts/checks/manifest-check.lisp` is the reproducer.
- The suite-structure scan visits 392 Lisp test files. `scripts/checks/suite-structure-check.pl .`
  is the reproducer.
- The historical attach-to-first-nonempty-PTY-output benchmark has recorded
  control and attach samples in `docs/src/benchmarks.md`. Its attach median
  changed from 89.115 ms to 131.448 ms, with a 32.976 ms control noise floor;
  this is not the current M1 first-visible-tree-row measurement.
- The key-update benchmark was unfinished when this note was written. The M3
  driver is now checked in under `scripts/benchmarks`, but its internal
  key-to-frame timing still needs to be measured.

## Coverage and deadlock baseline

- The coverage runner now includes `src/` and every `packages/*/src/` root,
  rejects an empty test selection and empty assertion journal, requires a
  non-empty report, and is registered as a flake check. Its per-test timeout
  is capped at 300 seconds and the outer Nix timeout is 2700 seconds.
- The former deadlock path was `pty-close` closing the PTY master and then
  calling `sb-ext:process-wait` on the same process object. The replacement
  polls process status and `kill(pid, 0)` until a five-second deadline and
  reports a timeout as an error.
- A local filtered PTY run was attempted but interrupted after the Nix daemon
  produced no output for more than 90 seconds. The pull request CI run remains
  the runtime evidence for the pre-fix tree; the post-fix runtime result must
  come from CI.

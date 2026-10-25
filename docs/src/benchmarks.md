# Benchmarks

This page records measured performance values, the commands used to obtain
them, and the limits on what each result supports. A performance claim needs a
recorded baseline.

Any performance claim in the documentation should refer to a measurement on
this page.

## `nix flake check` runtime

**Target**: 5 minutes. **Cap**: 10 minutes. Run
`nix flake check --print-build-logs` for the current check graph; source and
test counts are intentionally not duplicated in this historical page.

Measured on the development machine (aarch64-darwin, Apple silicon), with the
sibling libraries and nixpkgs dependencies already in the local store, so the
figures cover nerimux's own derivations only:

| Date | Scope | Wall clock |
|---|---|---|
| 2026-07-26 | `nix flake check` before the check graph expansion, 3 checks (`default`, `weave`, `dataflow`), all rebuilt | 157 s |
| 2026-07-26 | `nix flake check` after the check graph expansion, 5 checks, with `default`, `weave`, `dataflow` and `formatting` rebuilt and `docs` cached | 78 s |

These are historical snapshots of earlier check graphs.

Both runs build the test derivations from scratch; only the dependency closure
is shared. The docs derivation was cached during the later run.

The current flake has a later check graph than either snapshot. It exposes one
Lisp test derivation, `default`, plus the
`formatting` and `docs` checks. The `weave` and `dataflow` checks in the table
are historical names; they are not current entry points. The wall-clock rows
have not been re-measured against the current tree and must not be quoted as
current.

## Shipped core image size

The conversion to the workspace-oriented UI removed 95 source files (the tmux command table,
the keystroke pipeline, control mode, the standalone entry point). The relevant
question is the effect on the shipped `nerimux.core`.

**It is not currently answerable to the precision this page once claimed.**
`nix build .#nerimux --rebuild` makes Nix's own determinism check fire: building
the *same, unchanged* source twice does not reproduce a byte-identical
`nerimux.core`. The build ends in
`save-lisp-and-die ... :compression t`, and the compressed size of an SBCL core
is sensitive to heap layout, symbol and hash-table ordering, gensym counters,
as well as source volume.

Observed spread between builds of identical source was on the order of 10^5
bytes, which is the same magnitude as the deltas that were being attributed to
code removal. A single `stat` per revision therefore cannot support a figure like
"800,016 bytes smaller", and that claim has been withdrawn rather than restated
with a different number.

To make this measurable: take several `--rebuild` samples per revision, establish
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

## Attach first-frame latency

The historical samples below came from a standalone PTY runner that is no
longer in the repository. It measured from just before `forkpty` launched
`attach` until the first non-empty PTY output, and used a matching `printf`
control run to estimate PTY and shell startup noise. The current live terminal
harness is documented in `tests/live/README.md`.
The P-perf M1 procedure below measures the first visible tree row rather than
the first PTY byte.

Measured on 2026-09-08, `aarch64-darwin`. The quiet-state check found no
running SBCL, Nix build/run/flake, test, or e2e process. The 1-minute load
average was 14.61 on a 16-CPU host at the start of the run; the 5- and
15-minute averages were higher, so the control range is retained in the
interpretation.

| Revision | Control samples (ms) | Control median | Attach samples (ms) | Attach median |
|---|---|---:|---|---:|
| `b6960917a8ba95f60be40a5811e227daa72ef46f` | 89.772, 72.541, 77.574, 73.072, 83.599 | 77.574 | 125.712, 85.924, 89.115, 88.926, 97.674 | 89.115 |
| `e48d01e5d894ab9271d8b95edaa711aeb45b3237` | 82.169, 96.803, 76.304, 109.280, 97.855 | 96.803 | 143.556, 124.048, 131.569, 131.448, 107.608 | 131.448 |

The control ranges are 17.231 ms for the first revision and 32.976 ms for the
second, so the recorded noise floor is 32.976 ms. The raw attach median
delta is **+42.333 ms**, which exceeds that floor and is recorded as an
observed regression in this run. After subtracting each revision's control
median, the delta is **+23.104 ms**, below the floor; the run therefore cannot
attribute the whole raw delta to changes between the revisions. This is not
evidence for a regression-free claim, and it should be repeated on a quieter
host before using it as a release performance baseline.

The P-perf procedure below is the maintained way to reproduce a tree-visible
attach measurement. The older PTY byte measurements remain historical results.

## Other measurements

A startup-time measurement is also needed because a terminal multiplexer is
something a person waits for. It has not been measured.

## P-perf reproduction procedure

Set `BASE_SOURCE_ROOT` and `CANDIDATE_SOURCE_ROOT` to clean workspaces at the
exact revisions being compared. Verify each full revision with `jj`, and set
`SOURCE_ROOT` to one workspace at a time when building. Use the same host,
terminal dimensions, GHQ root, Git configuration, runtime, and Nix inputs for
both revisions. For M5, keep all Nix inputs fixed except the `cl-process-kit`
input being compared. Record each clean source revision, `flake.lock` digest,
runtime versions, and live harness digest. For runs that use a built Nerimux
artifact, also record its path and binary/core digests. M2 loads source through
ASDF and has no Nerimux binary or core artifact; its clean source revision
identifies the code being measured. Use
`shasum -a 256 "$SOURCE_ROOT/flake.lock"` and
`shasum -a 256 "$SOURCE_ROOT/tests/live/harness"` to record the lock-file and
harness digests. Keep the build and measurement steps serialized. Do not
measure while another build, test suite, or benchmark is using the host.

Record the full source revision from each clean workspace with
`jj --repository "$SOURCE_ROOT" log --ignore-working-copy -r @ -n 1 --no-graph -T commit_id`.
Capture the artifact path printed by the build command when the arm uses a
Nerimux artifact. M3 takes the paths `$ARTIFACT/bin/nerimux` and
`$ARTIFACT/lib/nerimux/nerimux.core`; M5 takes the artifact path. Record the
binary and core digests with `shasum -a 256`:

```bash
shasum -a 256 "$BUILT_ARTIFACT/bin/nerimux" "$BUILT_ARTIFACT/lib/nerimux/nerimux.core"
```

Record the exact SBCL and Git executable paths and their `--version` output.
Run `"$SBCL" --version` and `"$GIT" --version` to capture those values. M3 also
requires the matching `SBCL_HOME`. Run the driver from the Nerimux Nix
development shell so its SBCL runtime matches the build, and fail preflight if
`SBCL_HOME` is unset:

Use these helpers in the same Bash session as the driver invocation:

```bash
source_revision() {
  jj --repository "$1" log --ignore-working-copy -r @ -n 1 --no-graph -T commit_id
}
sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}
SBCL="$(command -v sbcl)"
GIT="$(command -v git)"
SBCL_VERSION="$("$SBCL" --version)"
GIT_VERSION="$("$GIT" --version)"
SBCL_HOME="${SBCL_HOME:?enter the Nerimux nix develop shell first}"
```

The checked-in M3 and M5 drivers are `scripts/benchmarks/m3-paired.py` and
`scripts/benchmarks/m5-paired.py`; their helpers are in the same directory.
There are no checked-in drivers for M1, M2, or M4. The commands in those
sections are driver interfaces, not self-contained commands: obtain and review
the matching external runner before starting. Set `M1_RUNNER`,
`M2_PREFLIGHT_RUNNER`, `M2_RUNNER`, `M2_PROFILE_RUNNER`, or `M4_RUNNER` to the
corresponding runner, and retain its source and digest with the raw results.
Create a fresh output directory for each invocation.

Keep the reviewed driver's noise-screen and pairing plan fixed across the
revisions, and retain that plan with the raw results. Record the maximum
allowed one-, five-, and fifteen-minute load averages. Run `uptime` immediately
before and after each sample. Defer the run unless each reading is at or below
4, 8, and 12, respectively. Do not change these limits during a run.

Use a monotonic clock for elapsed times. Run a same-code noise screen with the
same workload and harness, then compare the revisions in balanced pairs.
Record the maximum-minus-minimum time in the noise screen as the observed
same-code spread; it is a noise screen, not a confidence interval. Treat a
paired difference within that spread as inconclusive. Alternate which revision
runs first in successive pairs to reduce time-order bias. Keep each pair's
workload and output signature identical. Reject a sample on a failed command,
incomplete marker, changed output, or changed workload. Retain the raw timings,
pair order, load readings, median, range, and paired deltas; do not use a median
alone to claim a speedup.

For M1, M3, and M4, build each revision with the same flake inputs and retain
the printed output path. M2 loads the source checkout through ASDF and does not
use the Nerimux binary artifact:

```bash
BUILT_ARTIFACT="$(nix build --no-link --print-out-paths "path:$SOURCE_ROOT#nerimux")"
BUILT_BINARY="$BUILT_ARTIFACT/bin/nerimux"
```

Run Nix builds through the host's configured heavy-build lock. Use the same
binary for all samples of one revision, and do not rebuild between paired
measurements.

### M1: attach to first visible tree row

Use a fresh lane and a fresh, empty fixture directory for each sample. Give
each sample a unique `LIVE_BASE_TMPDIR`. Set `GHQ_ROOT` to the same populated
root for both revisions, using the setup described in M3 if needed. Require a
visible repository row under `Repositories` before timing, and do not change
the root between arms. Run the live harness self-check before timing.
The external driver accepts the selected binary and a unique sample label.
It starts a fresh lane and saves the pane capture, capture interval, workload
signature, and binary digest for each sample. Run it from the matching source
workspace and verify the source revision before each arm. The saved historical
M1 runner is candidate-specific; it cannot validate a baseline checkout. Use a
separate reviewed baseline runner or a parameterized runner that verifies both
revisions. Invoke the selected arm's runner with:

```bash
export LIVE_BASE_TMPDIR="$(mktemp -d)"
export LIVE_LANE=L1
export LIVE_FIXTURE_ROOT="$LIVE_BASE_TMPDIR/fixture-empty"
mkdir -p "$LIVE_FIXTURE_ROOT"
export GHQ_ROOT="$GHQ_ROOT_FOR_RUN"
export NERIMUX_BIN="$BUILT_BINARY"
tests/live/harness self-check L1
python3 "$M1_RUNNER" "$NERIMUX_BIN" "$SAMPLE_LABEL"
```

The driver starts a monotonic timer immediately before
`tests/live/harness start L1 "$NERIMUX_BIN"` launches `nerimux attach`. The
driver then polls `tmux -L nmx-L1 capture-pane -p -t app:0.0` every 10 ms
with the full lane environment from the harness, including `HOME`, `TMPDIR`,
`GHQ_ROOT`, `XDG_STATE_HOME`, `PATH`, `TMUX_TMPDIR`, `GIT_CONFIG_GLOBAL`,
`TERM`, and `LANG`. The harness `wait-for` command polls every 100 ms and is
too coarse for this measurement. Stop at the first non-header tree row under the
`Repositories` section; PTY startup bytes and the empty loading screen do not
end the sample. Save the first matching pane, capture interval, workload
signature, and binary digest. The target is 1.0 s or less.

### M2: complete status pass

Use the real GHQ root and record the workload signature before starting. M2
loads `nerimux-vcs` from the source checkout through ASDF; it does not run the
built Nerimux binary. Run each arm from its matching clean source workspace and
record that workspace's revision. Prepare a separate fresh `M2_RUN_ROOT` per
arm with the runner's `L8` directories for `HOME`, `TMPDIR`, `XDG_STATE_HOME`,
`TMUX_TMPDIR`, and Git fixtures/configuration. Set
`NERIMUX_SIBLING_REGISTRY` to the colon-separated sibling package source roots
used by the runner. Run its environment and source-loading preflight before
sampling:

```bash
bash "$M2_PREFLIGHT_RUNNER" "$M2_RUN_ROOT"
```

Do not reuse a prior run root. The external measurement wrapper takes the run
root and a sample ID accepted by that runner:

```bash
cd "$SOURCE_ROOT"
bash "$M2_RUNNER" "$M2_RUN_ROOT" "$SAMPLE_ID"
```

Use balanced pairs, alternate which arm runs first between pairs, and save the
order with the raw results. The Lisp runner calls `refresh-workspace-organizations-async`, records
the organization/repository/worktree counts and load in `on-catalog`, starts
its monotonic timer there, and stops in `on-complete`. Retain `status`, elapsed
time, the three load averages, scan and repository error counts, callback
counts, and workload signature. Also run `uptime` immediately before and after
each sample; reject samples outside the shared load gate. Compare only runs
with the same workload. The target is 3 s or less.

For the supporting profile, run the profile wrapper once from each matching
source workspace against the same GHQ root and isolated environment. Retain the
profile report separately: its concurrent accumulated Git times are not wall
clock time, and the report does not contain a sample load reading. The profile
wrapper takes the run root:

```bash
cd "$SOURCE_ROOT"
bash "$M2_PROFILE_RUNNER" "$M2_RUN_ROOT"
```

### M3: key receive to changed frame send

Use the same stable GHQ root for both revisions. The checked-in driver creates
a fresh isolated live-harness lane, obtains the GHQ root with `ghq root`, starts
the attached session, waits for the catalog and a stable selection, and records
the initial tree and selection signatures. The picker must display
organization, repository, and worktree entries. The next selection must be
unique, and `n` must advance the selection before a sample is accepted. The
driver sends the key only after the pre-sample load gate passes.

If the GHQ root is empty, set `REPOSITORY_URL` to a cloneable URL for a
repository under an organization and run `ghq get "$REPOSITORY_URL"` before
either arm. Keep the root and its repositories/worktrees unchanged across the
pair. Before measuring, verify the picker shows those entries and has a unique
next selection; the driver rejects a sample if either condition fails.

Create a fresh fixture directory for the runner's global Git configuration.
This avoids including host-specific settings:

```bash
export M3_FIXTURE_ROOT="$(mktemp -d)"
mkdir -p "$M3_FIXTURE_ROOT/includes"
: > "$M3_FIXTURE_ROOT/includes/first.gitconfig"
: > "$M3_FIXTURE_ROOT/includes/second.gitconfig"
: > "$M3_FIXTURE_ROOT/excludes"
cat > "$M3_FIXTURE_ROOT/gitconfig-global" <<EOF
[include]
    path = $M3_FIXTURE_ROOT/includes/first.gitconfig
[include]
    path = $M3_FIXTURE_ROOT/includes/second.gitconfig
[core]
    excludesFile = $M3_FIXTURE_ROOT/excludes
EOF
test -f "$M3_FIXTURE_ROOT/excludes"
```

The driver validates this fixture, copies `gitconfig-global` into its isolated
lane, and sets `GIT_CONFIG_GLOBAL` to that copy. Build both source revisions
with the same inputs and capture their output paths:

```bash
BASE_REVISION="$(source_revision "$BASE_SOURCE_ROOT")"
CANDIDATE_REVISION="$(source_revision "$CANDIDATE_SOURCE_ROOT")"
BASE_ARTIFACT="$(nix build --no-link --print-out-paths "path:$BASE_SOURCE_ROOT#nerimux")"
CANDIDATE_ARTIFACT="$(nix build --no-link --print-out-paths "path:$CANDIDATE_SOURCE_ROOT#nerimux")"
```

Then set each artifact's binary and core paths and digests:

```bash
BASE_BINARY="$BASE_ARTIFACT/bin/nerimux"
BASE_CORE="$BASE_ARTIFACT/lib/nerimux/nerimux.core"
BASE_BINARY_SHA256="$(sha256_file "$BASE_BINARY")"
BASE_CORE_SHA256="$(sha256_file "$BASE_CORE")"
CANDIDATE_BINARY="$CANDIDATE_ARTIFACT/bin/nerimux"
CANDIDATE_CORE="$CANDIDATE_ARTIFACT/lib/nerimux/nerimux.core"
CANDIDATE_BINARY_SHA256="$(sha256_file "$CANDIDATE_BINARY")"
CANDIDATE_CORE_SHA256="$(sha256_file "$CANDIDATE_CORE")"
```

Pass both clean source workspaces, full revisions, those artifact paths and
digests, runtime versions, fixture root, and output directory. The driver
requires identical `flake.lock` files, runs the noise screen, alternates pair
order, and preserves a summary plus every raw record. Invoke it with the same
inputs as the builds. Use a fresh output directory:

```bash
M3_OUTPUT_DIR="$(mktemp -d)"
python3 scripts/benchmarks/m3-paired.py \
  --baseline-source-root "$BASE_SOURCE_ROOT" \
  --baseline-source-revision "$BASE_REVISION" \
  --baseline-binary "$BASE_BINARY" \
  --baseline-binary-sha256 "$BASE_BINARY_SHA256" \
  --baseline-core "$BASE_CORE" \
  --baseline-core-sha256 "$BASE_CORE_SHA256" \
  --candidate-source-root "$CANDIDATE_SOURCE_ROOT" \
  --candidate-source-revision "$CANDIDATE_REVISION" \
  --candidate-binary "$CANDIDATE_BINARY" \
  --candidate-binary-sha256 "$CANDIDATE_BINARY_SHA256" \
  --candidate-core "$CANDIDATE_CORE" \
  --candidate-core-sha256 "$CANDIDATE_CORE_SHA256" \
  --sbcl "$SBCL" --sbcl-home "$SBCL_HOME" --sbcl-version "$SBCL_VERSION" \
  --git "$GIT" --git-version "$GIT_VERSION" \
  --fixture-root "$M3_FIXTURE_ROOT" --output-dir "$M3_OUTPUT_DIR"
```

The driver starts the harness and performs setup and key injection itself; do
not manually interact with the terminal during a sample. It instruments
`nerimux/transport:READ-FRAME` to timestamp the decoded `n` key,
`nerimux::%HANDLE-MULTI-CLIENT-MESSAGE` to confirm dispatch, and
`nerimux::%SEND-CLIENT-FRAME` to timestamp completion of the changed frame
send. Use `get-internal-real-time` for both timestamps and calculate the
receive-to-send interval inside the server. Confirm that the key and frame use
the same connection, dispatch returned, the frame changed, the selected row
advanced to the next row, and the new row is visible. Require both the server's armed
and completion markers, and save the before/after frame signatures. External
polling delay is not part of this metric. The target is 130 ms or less.

### M4: picker frame construction

Use a paired external frame driver; no M4 runner or plan schema is checked in.
The historical launcher is pinned to specific workspaces and artifacts, so it
is not a reusable command for a new pair.
Record the driver's source and digest, actual command line, both source
revisions, artifact paths and digests, and the exact workload signature. Record
organization, repository, worktree, pane, picker item, and repository error
counts, plus terminal dimensions; require the same nonempty signature and
dimensions on both arms. Warm `%render-client-frame` before timing a complete
frame with the same monotonic clock. Alternate which arm runs first in each
balanced pair and record the order. Record `uptime` immediately before and
after each sample and keep the load readings with the result. Each result must
include source and artifact identity, load, dimensions, elapsed time, warmup
and measured counts, non-empty frame byte length and hash, runner exit, and
post-check status. Require frame length and hash to match across both arms.

The target is 16 ms or less.

### M5: Git invocation with `:directory`

Build separate arms from the same Nerimux source revision, varying only the
`cl-process-kit` input between its baseline and candidate revisions. Record
both process-kit revisions and verify that each runner loaded the expected
source. The checked-in driver accepts both frozen process-kit workspaces and
verifies the source tree loaded by each arm. For example:

```bash
set -euo pipefail
NERIMUX_SOURCE_REVISION="$(source_revision "$NERIMUX_SOURCE_ROOT")"
PK_BASELINE_REVISION="$(source_revision "$PK_BASELINE_SOURCE_ROOT")"
PK_CANDIDATE_REVISION="$(source_revision "$PK_CANDIDATE_SOURCE_ROOT")"
M5_BASE_ARTIFACT="$(nix build --no-link --print-out-paths \
  --override-input cl-process-kit "path:$PK_BASELINE_SOURCE_ROOT" \
  "path:$NERIMUX_SOURCE_ROOT#nerimux")"
M5_CANDIDATE_ARTIFACT="$(nix build --no-link --print-out-paths \
  --override-input cl-process-kit "path:$PK_CANDIDATE_SOURCE_ROOT" \
  "path:$NERIMUX_SOURCE_ROOT#nerimux")"
```

Create a disposable seed repository and a linked worktree, then use that same
worktree as the target for both arms. Use Jujutsu and Git versions that support
`jj workspace add --colocate`; record `jj --version` and `git --version`, then
verify the target appears in `git worktree list --porcelain`. For example:

```bash
M5_SETUP_ROOT="$(mktemp -d)"
M5_SEED_REPO="$M5_SETUP_ROOT/seed"
M5_GIT_TARGET="$M5_SETUP_ROOT/target"
mkdir -p "$M5_SEED_REPO"
jj git init "$M5_SEED_REPO"
jj -R "$M5_SEED_REPO" new -m benchmark-seed
jj -R "$M5_SEED_REPO" workspace add --colocate --name m5-git-target \
  --revision @ "$M5_GIT_TARGET"
git -C "$M5_GIT_TARGET" rev-parse --show-toplevel
git -C "$M5_GIT_TARGET" worktree list --porcelain
```

Set the binary and core digests for both built artifacts:

```bash
M5_BASE_BINARY_SHA256="$(sha256_file "$M5_BASE_ARTIFACT/bin/nerimux")"
M5_BASE_CORE_SHA256="$(sha256_file "$M5_BASE_ARTIFACT/lib/nerimux/nerimux.core")"
M5_CANDIDATE_BINARY_SHA256="$(sha256_file "$M5_CANDIDATE_ARTIFACT/bin/nerimux")"
M5_CANDIDATE_CORE_SHA256="$(sha256_file "$M5_CANDIDATE_ARTIFACT/lib/nerimux/nerimux.core")"
```

Give the M5 driver the frozen Nerimux and process-kit source revisions, both
build artifacts and their digests, runtime versions, and the shared Git target.
Use a fresh output directory, then invoke it with these inputs:

```bash
M5_OUTPUT_DIR="$(mktemp -d)"
python3 scripts/benchmarks/m5-paired.py \
  --nerimux-source-root "$NERIMUX_SOURCE_ROOT" \
  --nerimux-source-revision "$NERIMUX_SOURCE_REVISION" \
  --pk-baseline-source-root "$PK_BASELINE_SOURCE_ROOT" \
  --pk-baseline-source-revision "$PK_BASELINE_REVISION" \
  --pk-candidate-source-root "$PK_CANDIDATE_SOURCE_ROOT" \
  --pk-candidate-source-revision "$PK_CANDIDATE_REVISION" \
  --baseline-artifact "$M5_BASE_ARTIFACT" \
  --baseline-binary-sha256 "$M5_BASE_BINARY_SHA256" \
  --baseline-core-sha256 "$M5_BASE_CORE_SHA256" \
  --candidate-artifact "$M5_CANDIDATE_ARTIFACT" \
  --candidate-binary-sha256 "$M5_CANDIDATE_BINARY_SHA256" \
  --candidate-core-sha256 "$M5_CANDIDATE_CORE_SHA256" \
  --sbcl "$SBCL" --sbcl-home "$SBCL_HOME" --sbcl-version "$SBCL_VERSION" \
  --git "$GIT" --git-version "$GIT_VERSION" \
  --git-target "$M5_GIT_TARGET" --output-dir "$M5_OUTPUT_DIR"
```

The driver runs the baseline and candidate arms with the same target. Time the
`git rev-parse --show-toplevel` invocation through
`nerimux/vcs::%run-git-read` with the target as its `directory` argument:

```lisp
(nerimux/vcs::%run-git-read target "rev-parse" "--show-toplevel")
```

Keep the Nerimux source, SBCL, Git version, target path, and environment fixed.
Warm the code path before timing the same invocation. Require a
non-empty result and matching output length and hash across warmup, samples,
and arms. Apply the same-code noise screen above to this invocation.
Record load averages around every sample. The target is 10 ms or less; a
difference within the observed same-code spread is inconclusive.

# Getting started

## Install and run

Nix is the only supported build path: it pins SBCL and every Lisp dependency,
so a build either reproduces exactly or fails loudly.

```bash
nix run github:nerima-lisp/nerimux -- attach
```

From a checkout:

```bash
nix build .                           # → ./result/bin/nerimux
./result/bin/nerimux attach
```

## Usage

```bash
nerimux                                # same as `attach` with no selector
nerimux attach                         # open the workspace overview
nerimux attach github.com/org/repo     # focus a repository by its ghq spec
nerimux attach /path/to/worktree       # open a local worktree
nerimux kill                           # stop the server (--force closes panes)
```

These examples assume `nerimux` is on `PATH`. From a checkout, use
`./result/bin/nerimux`; with no build, prefix the command with
`nix run github:nerima-lisp/nerimux --`.

`attach` auto-starts the headless runtime and connects a thin client. Running
`nerimux` with no command at all defaults to `attach`; `attach`, `server`,
and `kill` are the only commands, and only an unrecognized command word
prints the usage summary and exits non-zero. `-V`/`-h` are the only global
flags. A selector containing a slash is resolved against the ghq catalog —
the full specification, `host/organization/repository` — or against a local
worktree path; a selector that matches both readings at once opens the
global picker with the selector pre-typed instead of guessing.

If the current directory is inside a worktree ghq already tracks — a
subdirectory of one counts too — `attach` skips the overview and opens
straight into that worktree's pane: the one last focused there, or a new
shell if none was open yet. This resolves against the running server's
catalog even before the initial scan has finished, by resolving and merging
just that directory's repository synchronously. The pane opens in normal
mode, with a mode chip (`NORMAL`, plus an `i to type` hint) at the left edge
of the status bar. An explicit selector (`attach github.com/org/repo`, `attach
/path/to/worktree`) still opens the overview with that item selected, not the
pane directly.

The overview tree appears as soon as the repository scan finishes; the
per-repository VCS status (dirty/ahead/behind flags) streams in afterwards,
since it runs `git status` across every repository. A repository the scan
cannot read — an incomplete or otherwise unreadable checkout — is kept in the
tree flagged `!` rather than aborting the scan. While the initial scan is
still running, attaching shows a placeholder screen (`scanning workspaces...`,
with a running repository count once the scan has found any) instead of an
empty tree; if the ghq root has no repositories at all once the scan
finishes, the overview shows that directly, with the ghq root path and a
`ghq get <owner>/<repo>` hint, rather than a permanently empty tree.

If `nerimux` has to auto-start the server — no server was already running for
the target session — it prints `nerimux: starting server...` to stderr before
the client's screen takes over, so the wait for the new server's socket does
not look like a hung shell.

If `attach` has to auto-start the server and something goes wrong, the
spawned server's stdout/stderr are captured to a per-session-name log file
rather than discarded, so a crash leaves a forensic trail. The path is
`nerimux/<name>.log` under a state-home directory resolved as `$XDG_STATE_HOME`
(falling back to `~/.local/state`), or under `$NERIMUX_RUNTIME_STATE` when
that's set — the same state-home resolution the runtime-state snapshot file
uses, so the two files always land in the same directory but never collide.
The log directory is created `0700`. See `%runtime-log-path` and
`%runtime-state-home` in `src/bootstrap/runtime-lifecycle.lisp`.

## Default key bindings

The workspace UI uses **`C-q`** as its prefix. The initial view is the
overview, unless the cwd-match above jumps straight to a worktree's pane;
`C-p` opens the global picker across organizations, repositories, worktrees,
and panes.

| Key | Action |
|---|---|
| `C-q d` | Detach while keeping the runtime session resident |
| `C-p` | Open the global picker |
| `o` / `d` | Overview / detail view |
| `j` / `k` | Move the selection one row |
| `J` / `K` | Jump to the next / previous repository row |
| `h` / `l` | Collapse / expand the selected organization or repository (in detail view: move focus to an adjacent pane) |
| `Enter` | Dive in: toggle an organization row open or closed; on a repository row, jump straight into its main worktree; on a worktree, window, or pane row, open its shell (or create one if none is open yet) |
| `n` | Create a worktree for the selected repository and jump straight into its shell |
| `X` | Delete the selected worktree (asks for confirmation) |
| `L` / `U` | Lock / unlock the selected worktree (asks for confirmation) |
| `/` | Filter the tree incrementally |
| `r` | Refresh the workspace catalog and VCS state |
| `i` / `c` / `:` | Input / copy / command mode |
| `Esc` | Close or cancel the active modal or mode |

### The overview tree

The overview is a single full-width tree — organization → repository →
worktree → window → pane — with no side panels. It opens **fully expanded
down to the pane level**: a window row is only shown when a worktree has more
than one window, since with exactly one window its panes attach directly
under the worktree row instead. Rows are ordered by activity rather than by
catalog order: whichever organization, repository, or worktree had output or
focus most recently sorts first among its siblings. Re-sorting only happens
when the catalog itself changes — a scan landing, a merge, a worktree
create/delete — never while a client is just moving the selection, so a row
never jumps out from under the cursor mid-navigation.

Each worktree row also carries a compact status cluster to the right of its
label: a state tag (`CLEAN`, `DIRTY`, `CONFLICT`, ...), ahead/behind counts
(`+N`/`-N`) when nonzero, a pane count (`Np`, or `Np!` once any pane has
exited), and a relative last-activity time (`now`, `Nm`, `Nh`, `Nd`). Below
the tree, a separator line, a 2-line detail panel describing whatever row is
selected, and a 1-line strip for the most recent message fill the rest of the
frame above the footer.

`/` starts an incremental, case-insensitive substring filter over the tree:
a row stays visible when its own text matches or any of its descendants'
does (so a matching pane keeps its worktree, repository, and organization
ancestors on screen). While typing the query the footer shows a `/query`
input prompt; `Enter` accepts the query and returns to normal navigation,
keeping it applied and shown thereafter as a muted `/query` chip in the
footer, while `Esc` cancels and clears it. A query that matches nothing
replaces the row list with a centered `no matches: /query` notice, so an
empty tree always reads as "filtered to zero", never as a broken screen.

### Creating a worktree

Press `n` on a selected repository to create a worktree right away: nerimux
generates a branch name (`wt-<timestamp>`), creates the worktree, and jumps
straight into its shell — there is no branch-name prompt in between. To pick
the branch name yourself, use the command line instead:

```
: wt-create --branch <name> --confirm
```

Both paths land you in the new worktree's shell as soon as it is ready —
selecting and creating both mean "enter it," not "select it and stop."

Inside the picker, every printable key is a character of the search query, so
the selection moves with **`C-p`** and **`C-n`** rather than `j` and `k`.
`C-r` toggles regex matching, `Enter` selects, `Esc` closes.

nerimux reads no configuration file; every key binding and layout value above
is a compiled-in constant.

## Development

```bash
nix develop                      # SBCL with every dependency on the registry
sbcl --script run-tests.lisp     # the full suite, exactly as CI runs it
nix flake check --print-build-logs   # build + every checks.* derivation
nix fmt                          # treefmt (nixfmt)
```

Inside `nix develop`, `nerimux-sbcl` wraps an `sbcl` invocation with ASDF and
the sibling-library registry already set up:

```bash
nerimux-sbcl --eval '(asdf:load-system "nerimux")' --eval '(nerimux:main)'
nix build .#coverage-report --print-build-logs
```

The coverage derivation writes the generated report to
`result/cover-index.html` (or to the path printed by `nix build` with
`--no-link --print-out-paths`).

The coverage gate requires 100% expression and branch coverage. The small
set of declaration-only, FFI-constant, and static-style source files excluded
from the report is listed explicitly in `scripts/coverage.lisp`; runtime code
and the behavior of those declarations' consumers remain in scope.

## Testing

`nix flake check` runs three derivations in parallel:

| Check | What it covers |
|---|---|
| `default` | the full unit + integration suite (`nerimux/test`) |
| `formatting` | treefmt / nixfmt over every tracked Nix file |
| `docs` | this site, built with `mkdocs --strict` |

The main suite runs on [cl-weave](https://github.com/nerima-lisp/cl-weave) and covers the VT100
emulator, layout geometry, copy mode, and the client/server protocol. The
runner is deliberately sequential — tests share global session/socket state.

Live PTY integration against a real shell is a separate system,
`nerimux/pty-test`, run with `nix run .#test-pty`. It was split out of the
main suite so that `nix flake check` does not imply a result for host PTY work
that cannot run in a sandbox without `/dev/ptmx`; run it yourself when touching
PTY code, because the flake gate does not include it.

There is also an end-to-end smoke script, `t/e2e/e2e-smoke.lisp`, kept out of
the ASDF test system because it needs a built binary and a real `/dev/ptmx`.
Like `nerimux/pty-test`, it is not part of `nix flake check`; run it
yourself. It runs headless `server`/`kill` scenarios against the binary as a
subprocess, then launches it with `attach`, enters `:input` mode with `i`,
sends a marker through the attached pane, verifies the rendered output, and
detaches with `C-q d`:

```bash
nix run .#e2e
```

or, against a manual build:

```bash
nix build .
nerimux-sbcl --script t/e2e/e2e-smoke.lisp result/bin/nerimux
```

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

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
nerimux attach                         # open the repolist view
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
subdirectory of one counts too — `attach` skips the repolist and opens
straight into that worktree's pane: the one last focused there, or a new
shell if none was open yet. This resolves against the running server's
catalog even before the initial scan has finished, by resolving and merging
just that directory's repository synchronously. The pane takes typing
directly — there is no mode to leave first; every nerimux key inside a pane
starts with `C-q` (see [Default key bindings](#default-key-bindings) below).
An explicit selector (`attach github.com/org/repo`, `attach
/path/to/worktree`) still opens the repolist with that item selected, not the
pane directly.

The overview tree appears as soon as the repository scan finishes; the
per-repository VCS status (dirty/ahead/behind flags) streams in afterwards,
since it runs `git status` across every repository. A repository the scan
cannot read — an incomplete or otherwise unreadable checkout — is kept in the
tree flagged `!` rather than aborting the scan. While the initial scan is
still running, attaching shows a placeholder screen (`scanning workspaces...`,
with a running repository count once the scan has found any) instead of an
empty tree; if the ghq root has no repositories at all once the scan
finishes, the repolist view shows that directly, with the ghq root path and a
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
`%runtime-state-home` in `src/runtime-lifecycle.lisp`.

## Default key bindings

The workspace UI follows [magit](https://magit.vc/)'s keymap. A client is
always at one of three **views** — `repolist`, `status`, or `pane` — and,
independently, may have a **modal** on top of that view (a transient menu,
a confirmation, the help view, the process log, the picker, an incremental
filter, the command line, or scrollback). With no modal up, where a keystroke
goes is derived entirely from the current view: `repolist` and `status` route
to the workspace keymap below, and `pane` sends every byte straight to the
shell. There is no `:normal`/`:input` distinction and no key to press before
typing into a pane — every nerimux-level key inside a pane starts with
**`C-q`** instead. The initial view is `repolist`, unless the cwd-match above
jumps straight into a worktree's pane; `C-p` opens the global picker across
organizations, repositories, worktrees, and panes from either `repolist` or
`status`.

(`CLIENT-CONN-VIEW` and `CLIENT-CONN-MODAL`, `src/server-multi-dispatch.lisp`,
are the two slots this model is built from; `%client-ui-keys-p` in the same
file is the one-line derivation described above.)

### The `repolist`/`status` keymap

| Key | Action |
|---|---|
| `n` / `p` | Move the selection one row |
| `M-n` / `M-p` | Jump to the next / previous section header |
| `Tab` | Expand or collapse the selected row: a repository's worktrees, a worktree's panes/changed files/recent commits, or a changed file's diff |
| `Shift-Tab` | Cycle the global visibility level (same as pressing `1`…`4` in sequence) |
| `1`–`4` | Set the global visibility level directly (`4` expands everything, `1` shows section headings only) |
| `Enter` | Dive in: open/create a worktree's shell, jump into a repository's main worktree, or toggle a section header |
| `q` | Step back one rung — closes an open transient, then clears an active filter, then leaves `status` for the focused pane (or `repolist` if none), in that order |
| `g` | Refresh the workspace catalog and VCS state |
| `$` | Open the process log of recent git writes |
| `/` | Filter the tree incrementally |
| `:` | Open the command line |
| `C-p` | Open the global picker |
| `?` | Open the dispatch menu (a transient listing every other transient) |
| `Esc` | Close or cancel the active modal |

`status` view only, once a worktree is selected:

| Key | Action |
|---|---|
| `s` / `S` | Stage the selected change / stage everything |
| `u` / `U` | Unstage the selected change / unstage everything |
| `k` | Discard the selected change — asks for confirmation first |
| `c` `P` `F` `b` `m` `r` `z` `l` `d` `f` `t` `X` `!` `w` | Open the matching transient directly — see below. From `repolist`, the same transients are reachable only through `?` |

Selecting a row that is not a file — a section header, a commit, a stash — and
pressing one of these reports that there is nothing to stage rather than acting
on something else. Paths are passed after `--`, so a file whose name begins
with a dash is never read as a git option.

### Transient menus

`?` opens the dispatch menu, magit-style: a panel of one-letter keys, each
opening a further menu of arguments (toggled with their own letter) and
actions. From `status`, most of these also have a direct single-key shortcut
(the table above). The full set, and which actions actually run something
versus report that they are not wired yet (source: `+transient-definitions+`,
`src/server-multi-dispatch-transient.lisp`):

| Key | Menu | Wired actions | Not wired in this build |
|---|---|---|---|
| `c` | Commit | amend, keep message (`git commit --amend --no-edit`) | commit with a new message — no text prompt exists |
| `P` | Push | push to `origin/<branch>`, toggling `-f`/`--force-with-lease`/`-F`/`--force` (confirms first when either is active) | push to another remote — no text prompt |
| `F` | Pull | pull from `origin/<branch>`, toggling `--rebase` | — |
| `b` | Branch | list branches; switch to the previous branch (`git switch -`) | create/delete a branch — no text prompt |
| `m` | Merge | merge upstream (`@{u}`) | merge another branch — no text prompt |
| `r` | Rebase | rebase onto upstream (`@{u}`, confirms first); abort rebase | — |
| `z` | Stash | stash changes; pop the latest stash | — |
| `l` | Log | — | show log — no pager exists in this build |
| `d` | Diff | — | show diff — no pager exists in this build |
| `f` | Fetch | fetch this repository; fetch the whole organization | — |
| `t` | Tag | list tags | create a tag — no text prompt |
| `X` | Reset | `reset --soft HEAD`; `reset --hard HEAD` (confirms first); clean untracked files `-fd` (confirms first) | — |
| `!` | Shell command | — | arbitrary shell execution — deliberately never wired; it is its own trust-boundary decision |
| `w` | Worktree | create a worktree and open its shell; delete/lock/unlock the selected worktree (each pre-fills the command line with e.g. `wt-delete --confirm` — press `Enter` to run it or `Esc` to cancel) | create with a chosen branch name — use `: wt-create --branch <name> --confirm` instead |
| `?` | Dispatch | opens any of the above; `k` opens the full-screen help view | — |

A "not wired" action reports so on screen (`"... not wired in this build"`)
and does nothing. Every one of them is blocked on the same missing piece: this
build has no free-text prompt, so anything needing a commit message, a branch
name, a tag name or a remote name has nowhere to read it from. The `:` command
line is the workaround where one exists, and the table names it.

### The `C-q` prefix

| Key | Action |
|---|---|
| `C-q -` / `C-q \|` | Split the focused pane's window down / right |
| `C-q x` | Close the focused pane |
| `C-q z` | Toggle zoom on the focused pane's window |
| `C-q h` / `j` / `k` / `l` | Move focus to the neighbouring pane |
| `C-q n` / `p` | Cycle through the current worktree's windows |
| `C-q w` | Switch to the `status` view for the focused pane's worktree (falls back to `repolist` if nothing is focused) |
| `C-q [` | Enter scrollback on the focused pane |
| `C-q d` | Detach while keeping the runtime session resident |
| `C-q Q` | Quit the server (asks for confirmation, showing how many panes are still open) |
| `C-q C-q` | Escape: drop any modal and hand the keyboard back to the current view |

`C-q F` and `C-q C-f` (fetch repository / fetch organization) are gone —
fetch is the `f` transient now, reachable from `status` directly or from
`repolist` via `?` f.

### Scrollback (`C-q [`)

This is the only place vi-style motion survives; it replaces what used to be
called copy mode.

| Key | Action |
|---|---|
| `j` / `k` | Move the cursor one line |
| `C-u` / `C-d` | Scroll half a page up / down |
| `g` / `G` | Jump to the top / bottom of scrollback |
| `/` / `?` | Search forward / backward |
| `n` / `N` | Repeat the last search forward / backward |
| `Space` | Begin a selection at the cursor |
| `y` | Yank the selection and leave scrollback |
| `q` | Leave scrollback without yanking |

### Retired — do not reintroduce

The overview/detail keymap this replaced bound `j` `k` `J` `K` `h` `l` `i`
`o` `d` (view switch) `r` (refresh) `X` (worktree delete) `L` `U` `n`
(worktree create) and `c` (copy mode), plus the `:normal`/`:input`/`:copy`
mode vocabulary itself. None of that survives: `j`/`k` are now `n`/`p`,
`o`/`d` no longer switch views (`C-q w` and `q` do), worktree create/delete/
lock/unlock moved under the `w` transient, refresh is `g`, and copy mode is
scrollback (`C-q [`). Two working key bindings (`C-q F`, `C-q C-f`) were also
retired outright, folded into the `f` transient. `1`–`4`, `Tab`,
`Shift-Tab`, and the transient menus are new; they have no old-keymap
equivalent to confuse them with.

### The repolist tree

The repolist view is a single full-width tree, with no side panels, built from
three fixed sections in this order:

- **Attention** — every worktree that needs attention (dirty, conflict,
  ahead/behind, or missing) or is holding an exited pane.
- **Active** — every other worktree that holds at least one open pane.
- **Repositories** — every repository, always shown, whether or not any of
  its worktrees appear above. A repository row is **collapsed by default**;
  `Tab` expands it to list its worktrees.

A worktree appears in at most one of Attention or Active, never both; a
clean, pane-less worktree shows only once its repository is expanded. An
Attention or Active worktree row reads `org/repo · branch`; a worktree row
under an expanded repository shows just its own branch, since the repository
row above it already names the org and repo. Rows are ordered by activity
rather than by catalog order: whichever repository or worktree had output or
focus most recently sorts first among its siblings. Re-sorting only happens
when the catalog itself changes — a scan landing, a merge, a worktree
create/delete — never while a client is just moving the selection, so a row
never jumps out from under the cursor mid-navigation.

Each worktree row also carries a compact status cluster to the right of its
label: a state tag (`CLEAN`, `DIRTY`, `CONFLICT`, ...), ahead/behind counts
(`+N`/`-N`) when nonzero, a pane count (`Np`, or `Np!` once any pane has
exited), and a relative last-activity time (`now`, `Nm`, `Nh`, `Nd`).

`Tab` on a worktree row inline-expands it one level deeper, in a fixed
order: its panes, its changed files, and its recent commits, skipping any
group that is empty. `Tab` on a changed-file row within that expansion
inline-expands its own diff, capped at 200 cached lines with a trailing
`... N more lines` row when the diff is longer. Below the tree, a separator
line, a 2-line detail panel describing whatever row is selected, and a
1-line strip for the most recent message fill the rest of the frame above
the footer — which itself is a 2-3 line contextual key panel, collapsing to
a single line when the terminal is shorter than 12 rows.

`/` starts an incremental, case-insensitive substring filter over the tree:
a row stays visible when its own text matches or any of its descendants'
does (so a matching pane or file keeps its worktree and repository ancestors
on screen, and penetrates a collapsed repository or folded section). While
typing the query the footer shows a `/query` input prompt; `Enter` accepts
the query and returns to normal navigation, keeping it applied and shown
thereafter as a muted `/query` chip in the footer, while `Esc` cancels and
clears it. A query that matches nothing replaces the row list with a
centered `no matches: /query` notice, so an empty tree always reads as
"filtered to zero", never as a broken screen.

`?` opens the dispatch transient (see [Transient menus](#transient-menus)
above); its `k` entry opens a full-screen help view listing every binding —
Navigate, `status`-only staging, the transient menus, the `C-q` prefix, and
scrollback. `q`, `Esc`, or `Enter` closes the help view; a pending
confirmation (such as `C-q Q`'s server-quit prompt) takes priority over
every other modal and stays on top of it.

### Creating a worktree

With a repository selected, open the Worktree transient (`w` from `status`,
or `?` then `w` from either view) and press `c` to create a worktree right
away: nerimux generates a branch name (`wt-<timestamp>`), creates the
worktree, and jumps straight into its shell — there is no branch-name prompt
in between. To pick the branch name yourself, use the command line instead:

```
: wt-create --branch <name> --confirm
```

Both paths land you in the new worktree's shell as soon as it is ready —
selecting and creating both mean "enter it," not "select it and stop."

Inside the picker, every printable key is a character of the search query, so
the selection moves with **`C-p`** and **`C-n`** rather than `n` and `p`.
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

The ordinary suite currently passes. The coverage report is also available in
report-only mode when investigating uncovered runtime paths; the thresholded
derivation remains the acceptance gate and must not be weakened or made to
pass by expanding the exclusion list.

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

There is also an end-to-end smoke script, `tests/e2e/e2e-smoke.lisp`, kept out of
the ASDF test system because it needs a built binary and a real `/dev/ptmx`.
Like `nerimux/pty-test`, it is not part of `nix flake check`; run it
yourself. It runs headless `server`/`kill` scenarios against the binary as a
subprocess, then launches it with `attach`, sends a marker through the
attached pane, verifies the rendered output, and detaches with `C-q d`:

!!! warning
    The `attach` scenario (`tests/e2e/attach-scenario.lisp`) still sends a
    leading `i` keystroke before the marker command, a holdover from the
    retired `:normal`/`:input` keymap. Since a pane now takes typing
    directly, that `i` lands as a literal character in the shell instead of
    switching modes, and the marker never appears. Verified by running it
    against this branch's build: `nix build .` then `nerimux-sbcl --script
    tests/e2e/e2e-smoke.lisp result/bin/nerimux attach` reports `FAIL attach --
    marker=MISSING`. This is a test-script regression from the keymap
    change, not a rendering defect; fix it in `tests/e2e/attach-scenario.lisp`
    before trusting this scenario's result again.

```bash
nix run .#e2e
```

or, against a manual build:

```bash
nix build .
nerimux-sbcl --script tests/e2e/e2e-smoke.lisp result/bin/nerimux
```

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

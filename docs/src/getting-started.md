# Getting started

## Install and run

Nix is the supported build path and provides SBCL and the Lisp dependencies.

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
nerimux attach                         # open the current worktree or repolist
nerimux attach github.com/org/repo     # select a repository in repolist
nerimux attach /path/to/worktree       # select a tracked worktree in repolist
nerimux kill                           # stop the server (--force closes panes)
```

These examples assume `nerimux` is on `PATH`. From a checkout, use
`./result/bin/nerimux`; with no build, replace `nerimux` with
`nix run github:nerima-lisp/nerimux --` and keep the remaining arguments.

nerimux discovers repositories through ghq's catalog and configured root.
Use `ghq get <owner>/<repo>` to add a repository before selecting it here.

`attach` auto-starts the headless runtime and connects a thin client. Running
`nerimux` with no command at all defaults to `attach`; `attach`, `server`,
and `kill` are the commands. `-V`/`-h` are the global
flags. A selector containing a slash is resolved against the ghq catalog —
the full specification, `host/organization/repository` — or against a local
worktree path; a selector that matches both readings at once opens the
global picker with the selector pre-typed instead of guessing.

If the current directory is inside a worktree ghq already tracks — a
subdirectory of one counts too — `attach` skips the repolist and opens
straight into that worktree's pane: the one last focused there, or a new
shell if none was open yet. The pane takes typing
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

The default session is named `0`. An argument without a slash, such as
`nerimux attach review`, selects a named session instead of a repository.
When `attach` auto-starts a server, its stdout/stderr go to
`nerimux/<name>.log`, so the default session uses `nerimux/0.log`.
Look under `$NERIMUX_RUNTIME_STATE` if set, otherwise `$XDG_STATE_HOME`
(falling back to `~/.local/state`).

## Default key bindings

The workspace UI follows [magit](https://magit.vc/)'s keymap. A client is
always at one of three **views** — `repolist`, `status`, or `pane` — and,
independently, may have a **modal** on top of that view (a transient menu,
a confirmation, the help view, the process log, the picker, an incremental
filter, the command line, or scrollback). With no modal up, where a keystroke
goes is derived entirely from the current view: `repolist` and `status` route
to the workspace keymap below, and `pane` sends every byte straight to the
shell. Every nerimux-level key inside a pane starts with
**`C-q`**. The initial view is `repolist`, unless the cwd-match above
jumps straight into a worktree's pane; `C-p` opens the global picker across
organizations, repositories, worktrees, and panes from either `repolist` or
`status`.

A workspace is a Git worktree with an optional agent and terminal panes.
Only one agent runs per workspace at a time; ordinary terminals can coexist
with it. Panes belong to windows, which you can split and cycle through.

`C-q` means Ctrl+Q: hold Ctrl while pressing Q, release it, then press the
next key in the sequence. `M-` denotes the Meta/Alt modifier.

### The `repolist`/`status` keymap

| Key | Action |
|---|---|
| `Up` / `Down` | Move the selection one row (`n` / `p` also work in `status`) |
| `n` (`repolist`) | Create a detached workspace without text input, then choose Codex or Claude |
| `a` (`repolist`) | Assign Codex or Claude to the selected existing workspace |
| `t` (`repolist`) | Open a new ordinary terminal in the selected workspace |
| `c` / `x` (`repolist`) | Start Claude / Codex in the selected workspace |
| `C` (`repolist`) | Toggle the selected workspace's completed state; marking a running agent's workspace completed asks for confirmation and leaves the agent running |
| `p` / `P` (`repolist`) | Prune the selected workspace / all eligible workspaces; see [Completing and pruning workspaces](#completing-and-pruning-workspaces) |
| `v` (`repolist`) | Open `status` for the selected worktree; selecting a repository uses its main worktree |
| `M-n` / `M-p` | Jump to the next / previous section header |
| `Tab` | Expand or collapse the selected row: a repository's worktrees, a worktree's panes/changed files/recent commits, or a changed file's diff |
| `Shift-Tab` | Cycle the global visibility level (same as pressing `1`…`4` in sequence) |
| `1`–`4` | Set the global visibility level directly (`4` expands everything, `1` shows section headings only) |
| `Enter` | Enter a workspace's live agent, otherwise its live terminal, otherwise choose an agent to assign; a repository uses its main worktree, a pane gains focus, and a section header toggles |
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

The lowercase `s`, `u`, and `k` actions require a file row; otherwise they
report `select a file first`. `S` and `U` act on the selected worktree.

### Transient menus

`?` opens the dispatch menu, magit-style: a panel of one-letter keys, each
opening a further menu of arguments (toggled with their own letter) and
actions. From `status`, most of these also have a direct single-key shortcut
(the table above). The full set, and which actions actually run something
versus report that they are not wired yet:

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
| `!` | Shell command | — | arbitrary shell execution |
| `w` | Worktree | create a detached workspace and choose an agent; delete/lock/unlock the selected worktree (each pre-fills the command line with e.g. `wt-delete --confirm` — press `Enter` to run it or `Esc` to cancel) | create with a chosen branch name — use `: wt-create --branch <name> --confirm` instead |
| `?` | Dispatch | opens any of the above; `k` opens the full-screen help view | — |

A "not wired" action reports so on screen (`"... not wired in this build"`)
and does nothing. Where a `:` command-line workaround exists, the table
names it.

### The `C-q` prefix

| Key | Action |
|---|---|
| `C-q -` / `C-q \|` | Split the focused pane's window down / right |
| `C-q x` | Close the focused pane |
| `C-q K` | Stop only the selected workspace's agent, preserving its terminals, layout, and current focus |
| `C-q t` | Open a new ordinary terminal in the selected workspace |
| `C-q z` | Toggle zoom on the focused pane's window |
| `C-q h` / `C-q j` / `C-q k` / `C-q l` | Move focus left / down / up / right, respectively |
| `C-q n` / `C-q p` | Cycle through the current worktree's windows |
| `C-q w` | Return directly to the workspace overview (`repolist`), keeping the focused pane's worktree selected |
| `C-q [` | Enter scrollback on the focused pane |
| `C-q d` | Detach while keeping the runtime session resident |
| `C-q Q` | Quit the server (asks for confirmation, showing how many panes are still open) |
| `C-q C-q` | Escape: drop any modal and hand the keyboard back to the current view |

### Scrollback (`C-q [`)

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

### The repolist tree

The repolist view is a single full-width tree, with no side panels, built from
three fixed sections in this order:

- **Attention** — every worktree that needs attention (dirty, conflict,
  ahead/behind, or missing) or is holding an exited pane.
- **Active** — every other worktree that holds at least one open pane.
- **Repositories** — every repository, always shown, whether or not any of
  its worktrees appear above. A repository row is **collapsed by default**;
  `Tab` expands it to list its worktrees.

A worktree appears in at most one of Attention or Active; a
clean, pane-less worktree shows only once its repository is expanded. An
Attention or Active worktree row prefixes its label with `org/repo · `;
under an expanded repository, it shows only the worktree label. That label
is the branch when present, `(bare)` for a bare checkout, or the worktree
path (falling back to its identifier). Organizations and repositories
retain catalog order. Within each repository, worktrees with generated
creation-time names sort newest first; other names follow in catalog order.
Pane output and focus changes do not reorder worktrees.

Each worktree row also carries a compact status cluster to the right of its
label: agent state (`agent:NONE`, `agent:RUNNING`, or `agent:EXITED`, with
`/Codex` or `/Claude` when assigned), Git state (`git:CLEAN`, `git:DIRTY`,
`git:CONFLICT`, ...), ordinary terminal count (`terminal:N`), nonzero
ahead/behind counts (`+N`/`-N`), and relative last-activity time (`now`, `Nm`,
`Nh`, `Nd`). Completed workspaces show `agent:COMPLETED`, or
`agent:RUNNING+COMPLETED` while their agent still runs. Narrow rows drop
activity time, ahead/behind counts, then terminal count before agent and Git
state.

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
centered `no matches: /query` notice.

`?` opens the dispatch transient (see [Transient menus](#transient-menus)
above); its `k` entry opens a full-screen help view listing every binding —
Navigate, `status`-only staging, the transient menus, the `C-q` prefix, and
scrollback. `q`, `Esc`, or `Enter` closes the help view; a pending
confirmation (such as `C-q Q`'s server-quit prompt) takes priority over
every other modal and stays on top of it.

### Creating a worktree

In `repolist`, select a repository or one of its workspaces and press `n`.
nerimux creates a detached workspace without asking for a name, then offers
Codex or Claude. To assign an agent to an existing workspace, select it and
press `a`. `Enter` focuses a live agent first, then a live terminal; if neither
exists, it opens agent assignment.

In the assignment menu, press `x` for Codex or `c` for Claude. `q` or `Esc`
cancels assignment. Before the first agent launch attempt, cancelling a
workspace just created by this flow also attempts to remove it, but refuses
if it has changed or is in use.
Cancelling assignment to an existing workspace leaves that workspace intact.

Creation fetches `origin/main` and checks out that commit without a branch
(detached HEAD). The new directory is under the repository's
`.worktrees/<creation-time>-<short-sha>` path; for a bare repository this is
`<repo>.git/.worktrees/...`. The repository must have an `origin` remote with
a `main` branch.

The chosen agent's executable, `codex` or `claude`, must be on the server's
`PATH`.

!!! warning
    The default agent commands are `codex --dangerously-bypass-approvals-and-sandbox`
    and `claude --dangerously-skip-permissions`. These bypass the agents'
    permission checks; Codex also bypasses its sandbox. Assign an agent only
    when you intend to give it that access.

From `repolist`, select a repository or worktree, then press `?`, `w`, `c`
for the same creation flow. From `status`, press `w`, `c` to open it.
To create with a branch name, use the command line instead:

```
: wt-create --branch <name> --confirm
```

The `wt-create --branch` path opens the new worktree's shell as soon as it is
ready; it does not open agent assignment.

### Completing and pruning workspaces

In `repolist`, `C` toggles completion for the selected workspace. Completion
does not stop an agent or remove files. If an agent is running, confirm the
completion prompt to leave it running and mark the workspace completed.
Selecting a live pane through the overview or picker, or successfully opening
a new terminal or agent, clears completion. Use `C-q K` to stop the selected
workspace's agent without closing ordinary terminals; this targets workspace
selection even when a different pane retains focus.

`p` prunes the selected workspace; `P` considers all workspaces. A workspace
is eligible only after completion or agent exit, with no live panes or
clients using its panes or windows. Merely selecting its row in `repolist`
does not count as an attachment; return clients to the overview and close
their pickers before pruning. The repository's primary checkout, bare
checkouts, and locked worktrees are excluded. Missing directories are not
pruned by this action; repair their Git worktree metadata separately.
Pending deletion or cancellation also prevents another prune operation on
the same workspace.

Prune removes eligible worktrees from disk. Candidates with no changed files
are removed without a confirmation prompt; unpushed or detached commits do
not themselves trigger confirmation. Preserve any commits you need before
pruning. Ignored files cause a refusal requiring manual review. For a
candidate with changed files, review
the workspace path and changed-file list in the confirmation before allowing
deletion. Cancelling that confirmation preserves only that candidate; `P`
continues with the remaining candidates. The result
message distinguishes removed, excluded, cancelled, and failed workspaces.

### Global picker

`C-p` opens the global picker from `repolist` or `status`.
Inside the picker, every printable key is a character of the search query, so
the selection moves with **`C-p`** and **`C-n`** rather than `n` and `p`.
`C-r` toggles regex matching, `Enter` selects, `Esc` closes.

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
`result/cover-index.html`. With `--no-link --print-out-paths`, open
`cover-index.html` inside the printed output directory.

The coverage gate requires 100% expression and branch coverage. The small
set of declaration-only, FFI-constant, and static-style source files excluded
from the report is listed explicitly in `scripts/coverage.lisp`; runtime code
and the behavior of those declarations' consumers remain in scope.

The ordinary suite is the fast regression gate. The strict coverage derivation
is a separate acceptance gate. To investigate uncovered paths, generate a
report without enforcing the gate:

```bash
NERIMUX_COVERAGE_REPORT_ONLY=1 nix develop --command sbcl \
  --dynamic-space-size 4096 --no-sysinit --no-userinit --disable-debugger \
  --script scripts/coverage.lisp /tmp/nerimux-coverage-report
```

Do not weaken the threshold or expand the exclusion list to hide executable
behavior.

## Testing

`nix flake check` includes these checks:

| Check | What it covers |
|---|---|
| `default` | the full unit + integration suite (`nerimux/test`) |
| `formatting` | treefmt / nixfmt over every tracked Nix file |
| `docs` | this site, built with `mkdocs --strict` |
| `read-check` | Lisp and ASDF files can be read by SBCL |
| `manifest-check` | test files are registered in the ASDF manifest |
| `export-check` | single-colon package references name exported symbols |
| `internal-call-check` | internal helper calls match their arities |
| `suite-structure-check` | tests are enclosed in a suite's `describe` form |

The main suite runs on [cl-weave](https://github.com/nerima-lisp/cl-weave) and covers the VT100
emulator, layout geometry, scrollback, and the client/server protocol. The
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

```bash
nix run .#e2e
```

or, against a manual build:

```bash
nix build .
nerimux-sbcl --script tests/e2e/e2e-smoke.lisp result/bin/nerimux
```

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

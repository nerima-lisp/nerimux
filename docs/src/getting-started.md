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
flags. A selector containing a slash is resolved either against the ghq catalog
using the full specification, `host/organization/repository`, or against a
local worktree path. A selector that matches both readings at once opens the
global picker with the selector pre-typed instead of guessing.

If the current directory is inside a worktree ghq already tracks (a
subdirectory counts too), `attach` skips the repolist and opens
straight into that worktree's pane: the one last focused there, or a new
shell if none was open yet. This resolves against the running server's
catalog even before the initial scan has finished, by resolving and merging
just that directory's repository synchronously. The pane takes typing
directly. There is no mode to leave first; every nerimux key inside a pane
starts with `C-q` (see [Default key bindings](#default-key-bindings) below).
An explicit selector (`attach github.com/org/repo`, `attach
/path/to/worktree`) still opens the repolist with that item selected, not the
pane directly.

The overview tree appears as soon as the repository scan finishes; the
per-repository VCS status (dirty/ahead/behind flags) streams in afterwards,
since it runs `git status` across every repository. An incomplete or otherwise
unreadable checkout is kept in the tree, flagged `✗`, rather than aborting the
scan. While the initial scan is
still running, attaching shows a placeholder screen (`scanning workspaces...`,
with a running repository count once the scan has found any) instead of an
empty tree; if the ghq root has no repositories at all once the scan
finishes, the repolist view shows that directly with the ghq root path and a
`ghq get <owner>/<repo>` hint, rather than a permanently empty tree.

If `nerimux` has to auto-start the server because no server was already running
for the target session, it prints `nerimux: starting server...` to stderr before
the client's screen takes over, so the wait for the new server's socket does
not look like a hung shell.

If `attach` has to auto-start the server and something goes wrong, the
spawned server's stdout/stderr are captured to a per-session-name log file
rather than discarded, so a crash leaves a forensic trail. The path is
`nerimux/<name>.log` under a state-home directory resolved as `$XDG_STATE_HOME`
(falling back to `~/.local/state`), or under `$NERIMUX_RUNTIME_STATE` when
that's set. Both paths use the same state-home resolution, so the two files
always land in the same directory but never collide.
The log directory is created `0700`. See `%runtime-log-path` and
`%runtime-state-home` in `src/runtime-lifecycle.lisp`.

## Default key bindings

The workspace UI follows [magit](https://magit.vc/)'s keymap. A client is
always at one of three **views**: `repolist`, `status`, or `pane`, and may
independently have a **modal** on top of that view (a transient menu,
a confirmation, the help view, the process log, the picker, an incremental
filter, the command line, or scrollback). With no modal up, where a keystroke
goes is derived entirely from the current view: `repolist` and `status` route
to the workspace keymaps below, and `pane` sends every byte straight to the
shell. There is no `:normal`/`:input` distinction and no key to press before
typing into a pane. Every nerimux-level key inside a pane starts with
**`C-q`** instead. The initial view is `repolist`, unless the cwd-match above
jumps straight into a worktree's pane; `C-p` opens the global picker across
organizations, repositories, worktrees, and panes from either `repolist` or
`status`.

(`CLIENT-CONN-VIEW` and `CLIENT-CONN-MODAL`, `src/server-multi-data.lisp`,
are the two slots this model is built from; `%client-ui-keys-p`, in
`src/server-multi-dispatch.lisp`, is the one-line derivation described above.)

### Keys shared by `repolist` and `status`

| Key | Action |
|---|---|
| `n` / `p` | Move the selection one row |
| `Up` / `Down` | Move the selection one row, the same as `n` / `p` |
| `Right` / `Left` | Expand / collapse the selected row |
| `M-n` / `M-p` | Jump to the next / previous section header |
| `Tab` | Expand or collapse the selected row: a repository's worktrees, a worktree's panes/changed files/recent commits, or a changed file's diff |
| `S-Tab` | Cycle the global visibility level |
| `1`–`4` | Set the global visibility level directly (`1` shows section headings only, `4` expands everything) |
| `Enter` | Dive in. On a worktree row: return to the pane last focused there if it is still live, else to its running agent, else to any live terminal, else to an exited pane that still holds a screen, else open the Assign transient. On a repository row: expand or fold it, the same as `Tab`, so its worktrees appear before anything is opened; a repository with no worktree reports `no worktree yet: w c creates one`. On a pane or window row: focus that pane. On a section or organization row: fold it |
| `q` | Step back one rung: close an open transient, then clear an active filter, then leave `status` for the focused pane (or `repolist` when there is none) |
| `g` | Refresh the workspace catalog and VCS state, dropping any settled failure badge first |
| `$` | Open the process log of recent git writes |
| `/` | Filter the tree incrementally |
| `:` | Open the command line |
| `C-p` | Open the global picker |
| `?` | Open the dispatch menu, the transient that reaches every other transient |
| `P` `F` `b` `m` `r` `z` `l` `d` `f` `X` `w` | Open the matching transient directly |
| `Esc` | Close the modal on top. With nothing open, `Esc` is discarded and the key struck after it is read normally |

`c`, `t`, and `!` open the Commit, Tag, and Shell-command transients from
`status` only. From `repolist` those three letters mean something else (next
table), and their transients are reached through `?`.

### `repolist` only

| Key | Action |
|---|---|
| `a` | Open the Assign transient for the selected worktree |
| `v` | Open the `status` view for the selected worktree |
| `t` | Open a shell pane in the selected worktree |
| `c` | Start Claude in the selected worktree |
| `x` | Start Codex in the selected worktree |

`c` and `x` launch the agents with the flags listed under
[Creating and assigning a worktree](#creating-and-assigning-a-worktree).

### `status` only

| Key | Action |
|---|---|
| `s` / `S` | Stage the selected change / stage everything |
| `u` / `U` | Unstage the selected change / unstage everything |
| `k` | Discard the selected change, after a confirmation. A staged file is restored in both the index and the worktree, an unstaged file in the worktree only, and an untracked file is deleted |
| `c` | Open the Commit transient |
| `t` | Open the Tag transient |
| `!` | Open the Shell-command transient |
| `v` | Step back, the same as `q` |

Selecting a row that is not a file (a section header, a commit, or a stash) and
pressing one of the staging keys reports `select a file first` rather
than acting on something else. `u` on an untracked file reports `nothing to
unstage`, since an untracked file was never in the index. Paths are passed
after `--`, so a file whose name begins with a dash is never read as a git
option.

Every transient, read-only view, and prompt opened from `status` acts on the
worktree the view itself is showing, whatever row the selection happens to be
on. Selecting a file, a commit, or a pane row does not retarget a push, a
fetch, or a log at something else.

The `status` footer is two lines. The first changes with the selected row:

- file row: `s stage  u unstage  k discard  Tab diff`
- commit row: `l log  d diff  Tab expand`
- stash row: `z stash  Tab fold`
- section row: `Tab fold  1..4 visibility  s/S stage  u/U unstage`
- pane row: `Enter focus  C-q x close (in pane)`
- anything else: `s/S stage  u/U unstage  c commit  P push  F pull  ? all menus`

The second line does not change:
`n/p move  v/q back  g refresh  ? menu  $ log  : command  C-q w repolist
C-q d detach`.

### Transient menus

`?` opens the dispatch menu, magit-style: a panel of one-letter keys, each
opening a further menu of arguments (toggled with their own letter) and
actions. From `status`, most of these also have a direct single-key shortcut
(the tables above). Inside a transient, `q` returns to the menu that opened it,
or closes it when nothing opened it, and `Esc` closes it outright. The full set
(source: `+transient-definitions+`, `src/server-multi-transient-data.lisp`):

| Key | Menu | Actions |
|---|---|---|
| `c` | Commit | `e` amend, keeping the message (`git commit --amend --no-edit`); `c` commit with a new message |
| `P` | Push | `p` push to upstream (a bare `git push` against the branch's configured upstream), with `f` `--force-with-lease` and `F` `--force` as arguments (either one confirms first); `e` push to another remote |
| `F` | Pull | `p` pull from upstream (a bare `git pull` against the branch's configured upstream), with `r` `--rebase` as an argument |
| `b` | Branch | `l` list branches; `-` switch to the previous branch (`git switch -`); `c` create a branch; `D` delete a branch |
| `m` | Merge | `u` merge upstream (`@{u}`); `b` merge another branch |
| `r` | Rebase | `u` rebase onto upstream (`@{u}`, confirms first); `a` abort the rebase |
| `z` | Stash | `z` stash changes; `p` pop the latest stash |
| `l` | Log | `l` show the selected worktree's log in a read-only pager |
| `d` | Diff | `d` show the selected worktree's diff in a read-only pager |
| `f` | Fetch | `f` fetch this repository; `F` fetch the whole organization |
| `t` | Tag | `l` list tags; `t` create a tag |
| `X` | Reset | `s` `reset --soft HEAD`; `h` `reset --hard HEAD` (confirms first); `c` clean untracked files `-fd` (confirms first) |
| `!` | Shell command | `!` is a stub: it reports that arbitrary shell execution is deliberately not wired, being its own trust-boundary decision |
| `w` | Worktree | the submenu below |
| `?` | Dispatch | opens any of the above; `k` opens the full-screen help view |

`!` is the only deliberate stub left in this table. Every other action runs
what it names. The one other entry that reports instead of acting is `w b`,
which points at the command line rather than at a branch chooser.

#### The `w` submenu

| Key | Action |
|---|---|
| `c` | Create a worktree and open a shell in it |
| `n` | Create a worktree and open the Assign transient over it |
| `a` | Assign an agent to the selected worktree |
| `k` | Delete the selected worktree |
| `l` | Lock the selected worktree |
| `u` | Unlock the selected worktree |
| `C` | Toggle the selected workspace complete |
| `p` | Prune the selected workspace, after a confirmation |
| `P` | Prune every eligible workspace, after a confirmation |
| `b` | Reports `use : wt-create --branch <name> --confirm` |

`k`, `l`, and `u` do not act directly: each pre-fills the command line with
`wt-delete --confirm`, `wt-lock`, or `wt-unlock`, and `Enter` runs it while
`Esc` cancels. A worktree is eligible for pruning when it is marked complete,
or its agent has exited, or its directory is missing, and it is not locked,
not the primary worktree, has no live panes, is not attached to a client, and
has no cancellation or deletion pending. `p`, `P`, and `: wt-prune-confirm
--confirm` all open the same confirmation panel in front of the prune; the
panel names, by `org/repo · branch`, any candidate with uncommitted changes,
which are deleted with it.

A confirmation panel names the operation and its effect, and takes `y` to
execute. `n`, `q`, `Esc`, and `C-q C-q` all cancel it; every other key is
swallowed while it is up, so the tree underneath cannot move while the question
is unanswered.

The `l` and `d` read-only views use `j`/`k` for line movement, `C-u`/`C-d`
for half-page movement, `/` or `?` for search, and `q` or `Esc` to close. The
search box shows what is typed so far and `Enter accept  Esc cancel`. Their
content is loaded asynchronously and remains separate from write operations.

A transient, a confirmation, and a text prompt all draw as a panel at the
bottom of the frame, titled with their own name, with the view they were
opened over still visible above.

Commit messages use a multiline prompt: `Enter` inserts a newline and `C-s`
submits. Branch names, tag names, and remote names use a one-line prompt where
`Enter` submits and `Esc` cancels. A name that starts with `-` is rejected
with `a name cannot start with -`.

### The `:` command line (FR-207)

The workspace command line accepts exactly these command names. Tree navigation,
picker control, and modal transitions are protocol commands and are not
available for manual entry; typing one reports `command is not available from
the : prompt: <name>`, with the command word you typed after the colon.

| Command | Action |
|---|---|
| `wt-create` | Create a worktree and open a shell in it, the same as `w c`. Requires `--confirm` and a branch, given as `--branch <name>` (or `-b`) or as the first positional word; `--path <dir>` and `--force` are optional. A bare positional `-` is not a branch name and is skipped, so it reports `worktree create requires a branch`. A branch name starting with `-` is rejected with `a name cannot start with -`. `--path` must stay under the repository (`path must stay under the repository`) and cannot start with `-` (`a path cannot start with -`) |
| `wt-delete` | Delete the selected worktree. Requires `--confirm` |
| `wt-lock` | Lock the selected worktree; `--reason <text>` is optional |
| `wt-unlock` | Unlock the selected worktree |
| `wt-prune` | Preview prunable worktrees without removing anything or opening a panel, using the same eligibility rule `w P` follows |
| `wt-prune-confirm` | Prune those worktrees for real. Requires `--confirm` |
| `wt-complete` | Toggle the selected worktree complete. Takes no arguments |
| `workspace-complete` | The same as `wt-complete` |
| `workspace-prune` | Prune the selected workspace, after a confirmation. Takes no arguments |
| `workspace-prune-all` | Prune every completed workspace, after a confirmation. Takes no arguments |
| `overview` | Open the repolist view |
| `detail` | Open the selected worktree's pane view |
| `refresh` | Refresh the workspace catalog and VCS state, dropping any settled failure badge first |
| `kill` | Stop the server, subject to its pane rules; `--force` closes open panes |

A command that needs `--confirm` and does not get it reports so and does
nothing, for example `wt-create: add --confirm to run`. Every worktree command
acts on the selected worktree unless `-t <spec>` (or `--target <spec>`) names
another one. A `-t` spec that resolves to nothing reports `target not found`
and the command does not fall back to the selected worktree.

These prompt inputs are not workspace commands and do not appear in the table
above:

| Input | Action |
|---|---|
| `:help` | Open the full-screen help view |
| `:q`, `:quit` | Step back one rung, the same as the `q` key |
| `:search-forward <text>` | Search the focused pane's scrollback forward |
| `:search-backward <text>` | Search the focused pane's scrollback backward |

`/` and `?` in scrollback open the command line with `search-forward ` or
`search-backward ` already typed. `Enter` submits what is typed, `Backspace`
deletes the last character, and `Esc` clears the prompt and closes it. `Tab`
completes a command name: the first press extends what is typed to the longest
prefix every candidate shares, and each press after that steps to the next
candidate.

### The `C-q` prefix

| Key | Action |
|---|---|
| `C-q -` / `C-q \|` | Split the focused pane's window down / right |
| `C-q <` / `C-q >` | Shrink / grow the focused pane horizontally by five cells |
| `C-q {` / `C-q }` | Shrink / grow the focused pane vertically by five cells |
| `C-q x` | Close the focused pane. While its process is still running, the first press only reports `C-q x again to close` and a second `C-q x` closes it; any other key in between cancels. A pane whose process has already exited closes on the first press |
| `C-q z` | Toggle zoom on the focused pane's window |
| `C-q h` / `j` / `k` / `l` | Move focus to the neighbouring pane |
| `C-q n` / `p` | Cycle through the current worktree's windows |
| `C-q t` | Open a shell pane in the selected worktree |
| `C-q K` | Stop the agent running in the selected worktree |
| `C-q w` | Return to the `repolist` overview, retaining the focused worktree selection |
| `C-q [` | Enter scrollback on the focused pane |
| `C-q ?` | Open the full-screen help view, the one `?` reaches from `repolist` and `status` |
| `C-q d` | Detach while keeping the runtime session resident |
| `C-q Q` | Quit the server (asks for confirmation, showing how many panes are still open) |
| `C-q C-q` | Escape: drop any modal and hand the keyboard back to the current view |

A key with no binding in this table is discarded: the prefix already consumed
it, and nothing else happens.

`C-q F` and `C-q C-f` (fetch repository / fetch organization) are gone.
Fetch is the `f` transient now, reachable from `status` directly or from
`repolist` via `?` f.

Splits start at 50/50 and can be resized with the bindings above (FR-105). A window has
no four-pane limit: splitting continues in the same window while every
resulting pane meets the model's minimum size. When a split would make a pane
too small, nerimux reports the refusal and leaves the window and pane lists
unchanged.

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

### Retired: do not reintroduce

The overview/detail keymap this replaced bound `j` `k` `J` `K` `h` `l` `i`
`o` `d` (view switch) `r` (refresh) `X` (worktree delete) `L` `U` `n`
(worktree create) and `c` (copy mode), plus the `:normal`/`:input`/`:copy`
mode vocabulary itself. None of that survives: `j`/`k` are now `n`/`p`,
`o`/`d` no longer switch views (`C-q w` returns to `repolist` and `q` steps
back), worktree create/delete/lock/unlock moved under the `w` transient,
refresh is `g`, and copy mode is scrollback (`C-q [`).

The later repolist bindings `n` (create a worktree), `p` (prune), `C` (toggle
complete), and `P` (prune all) are retired too. `n` and `p` now move the
selection in both views, `P` opens the Push transient, and the four actions
live at `w n`, `w p`, `w C`, and `w P`.

Two working key bindings (`C-q F`, `C-q C-f`) were also retired outright,
folded into the `f` transient. `1`–`4`, `Tab`, `S-Tab`, and the transient menus
are new; they have no old-keymap equivalent to confuse them with.

### The repolist tree

The repolist view is a single full-width tree, with no side panels, built from
three fixed sections in this order:

- **Attention**: every worktree that is actionable right now: a merge
  conflict, a missing checkout, a waiting agent, or an exited pane. A worktree
  that is merely dirty, ahead, or behind stays under its repository, carrying
  the `!` mark; in a worktree-per-task workflow those states are the norm, and
  listing every one of them here buried the rest of the tree.
- **Active**: every other worktree that holds at least one open pane.
- **Repositories**: every repository, always shown, whether or not any of
  its worktrees appear above, grouped under one row per organization
  (`github.com/org (N)`). A repository row names the repository alone and
  carries a summary cluster to its right: `N worktrees`, `N active` (holding
  a pane), and `N !` (needing attention), each omitted when zero. A
  repository row is **collapsed by default**; `Enter` or `Tab` expands it to
  list its worktrees, and an organization row folds the same way.

A worktree appears in at most one of Attention or Active, never both; a
clean, pane-less worktree shows only once its repository is expanded. An
Attention or Active worktree row reads `org/repo · branch`; a worktree row
under an expanded repository shows just its own branch, since the repository
row above it already names the org and repo. Rows are ordered by activity
rather than by catalog order: whichever repository or worktree had output or
focus most recently sorts first among its siblings. Re-sorting only happens
when the catalog itself changes (a scan landing, a merge, or a worktree
create/delete), never while a client is just moving the selection, so a row
never jumps out from under the cursor mid-navigation.

Each worktree row carries a compact status cluster to the right of its label.
Every token in it is omitted when it has nothing to say, and a row too narrow
to hold them all drops the least important first:

| Token | Meaning |
|---|---|
| `now`, `Nm`, `Nh`, `Nd` | How long ago a pane under this worktree last produced output or held focus |
| `+A`, `−D` | Added and deleted lines; each half is omitted when it is zero |
| `↑N`, `↓N` | Commits ahead of and behind the upstream branch |
| `1 shell`, `N shells` | Non-agent panes open in this worktree |
| `exited` | One of its panes has lost its process |
| `completed` | The workspace is marked complete |
| `agent RUNNING`, `agent WAITING`, `agent EXITED` | The agent's lifecycle; absent when no agent has run here |
| `dirty`, `conflict` | The Git state. `missing`, `locked`, and `prunable` share this slot and take precedence over `dirty`/`conflict`; a clean worktree shows no state word |
| `refreshing`, `stale` | A status read is in flight, or the last one failed |

Separately from that cluster, a repository or worktree row carries a short
badge next to its label while a scan, status read, fetch, worktree create, or
prune runs against it: `...`. If the operation fails, the badge instead reads
`failed: <reason>`, or plain `failed` when there is no reason to show; a read
failure (scan or status) reports `read failed`. Pressing `g`, or
running the `refresh` command, drops every settled failure badge before
rescanning, so a stale failure never survives a manual refresh.

Each row also begins with two glyph columns. The first is `▾` when the row is
expanded, `▸` when it is collapsed, and blank for a row with nothing under it.
The second is `✗` when the checkout could not be read, `!` when the worktree
is dirty, ahead, behind, in conflict, missing, holding a waiting agent, or
holding an exited pane, and blank otherwise. Only the last four of those also
place the worktree under Attention; the first three mark it in place. A
repository or organization row carries `!` when anything beneath it does.

Process exit or a BEL or recognized terminal notification marks an agent
`WAITING`; focusing its pane clears that state (FR-201). Unread output on an
unfocused pane marks that pane, and leaves its worktree under Active rather
than moving it to Attention.

A pane row names what it runs, the agent or `shell`, and adds `exited` once
its process is gone. A changed-file row names its state as a word, `modified`,
`added`, `deleted`, `untracked`, `renamed`, `copied`, `typechange`, `ignored`,
or `conflict`, followed by the path, rather than git's porcelain `XY` codes.

When no attached client is focusing a waiting agent, attached clients receive
a host-terminal notification (FR-202).

`Tab` on a worktree row inline-expands it one level deeper, in a fixed
order: its panes, its changed files, and its recent commits, skipping any
group that is empty. `Tab` on a changed-file row within that expansion
inline-expands its own diff, capped at 200 cached lines with a trailing
`... N more lines` row when the diff is longer. Visibility level 4 opens the
same three groups at once, recent commits included; a worktree whose history
has not been read yet shows a `loading` row there until it arrives. Below the
tree, a separator line, a 2-line detail panel describing whatever row is selected, and a
1-line strip for the most recent message fill the rest of the frame above
the footer, which itself is a 2-3 line contextual key panel, collapsing to
a single line when the terminal is shorter than 12 rows.

The repolist footer's first line follows the selected row: a section row
offers `Enter/Tab fold  M-n/M-p section  1-4 level  / filter  C-p picker
g refresh`, an organization row `Enter/Tab fold  n/p select  g refresh`, a
repository row `Enter/Tab expand  w worktree menu  f fetch menu`, a pane row `Enter focus  n/p select
C-q x close (in pane)`, and a
worktree row `Enter agent>terminal>assign  Tab expand  w worktree menu
c/x Claude/Codex  g refresh`, each prefixed with `a assign  v status`. Its
second line is fixed: `q back  ? menu  $ log  : command  C-q w repolist
C-q d detach`.

### Messages

Anything nerimux has to say about a key you pressed, a refusal, a git write, or
a worktree it created, appears on the 1-line message strip. In the pane view
the same text takes over the right-hand side of the status bar, so a refused
split or a `worktree created: <path>` line is visible there too; a long path
is elided from the left.

A message stays until the next key you press, until you change view, or for
five seconds, whichever comes first. Nothing has to be dismissed, and a
message never outlives the action that raised it.

`$` opens the process log, a scrollable record of the git commands nerimux has
run for you and what each of them printed. `n` and `p` scroll it; `q` or `Esc`
closes it.

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
above); its `k` entry, labelled `Help (all keys)`, opens a full-screen help
view with one section per table on this page: Navigate, Repolist, Status, the
transient menus, the `w` submenu, the `C-q` prefix, scrollback, and panes. The
Navigate section lists `Right` and `Left` beside `n` and `p`, so the arrow keys
are discoverable without reading this page. From a pane the same view opens
with `C-q ?`. `q`, `Esc`, or `Enter` closes the help view; a pending
confirmation (such as `C-q Q`'s server-quit prompt) takes priority over every other modal and stays
on top of it.

### Creating and assigning a worktree

With a repository selected, `w n` fetches its default branch, creates a
detached worktree, selects it, and opens the Assign transient over it. `w c`
creates the same worktree and opens a shell in it directly, skipping the
transient, which is what its menu entry `create worktree and open its shell`
says. To pick the branch name yourself, use `w b`, which tells you the command
to type, or type it directly:

```
: wt-create --branch <name> --confirm
```

The command line takes the `w c` path: the worktree is created and a shell
opens in it. Press `a` afterwards to reach the Assign transient, or use `w n`
when you want the menu first.

To assign an existing worktree, select it and press `a` (or `w a`). `Enter` on
a worktree row returns to the pane last focused there if it is still live,
then to its running agent, then to any live terminal, then to an exited pane
that still holds a screen, and opens the Assign transient only when none of
those apply.

The Assign transient is titled `Assign agent` and offers:

| Key | Action |
|---|---|
| `x` | Codex (bypass sandbox), `codex --dangerously-bypass-approvals-and-sandbox` |
| `c` | Claude (skip permissions), `claude --dangerously-skip-permissions` |
| `t` | Terminal, your ordinary shell |
| `k` | Discard the worktree |
| `q`, `Esc` | Close the menu and keep the worktree |

Closing the menu is not a request to delete anything: the worktree stays, still
selected, with no pane open yet, and `k` is the only key that discards it. The
repolist keys `c`, `x`, and `t` start the same three commands directly, without
going through the menu.

### The global picker

`C-p` opens the global picker over whichever view you were in, and `Esc`
returns you to that same view. It searches organizations, repositories,
worktrees, and panes, and every printable key is a character of the query, so
the selection moves with `C-n` and `C-p` rather than `n` and `p`.

| Key | Action |
|---|---|
| `C-n` / `C-p` | Move the selection |
| `Enter` | Open the selected row |
| `C-r` | Toggle regex matching |
| `Backspace` | Delete the last query character |
| `Esc` | Close the picker |

The panel is titled `Pick a worktree, repository or pane`, and its status line
carries the result count followed by `C-n/C-p move  Enter open  C-r regex
Esc close`. With regex matching on, `regex on` sits beside the query; a pattern
the engine cannot compile reports `regex: unsupported pattern, matching
literally` and the query is matched as plain text.

`Enter` opens a worktree or a pane. On a repository row it jumps to that
repository's main worktree, or, when the repository has none, selects and
expands the repository row; on an organization row it expands and selects the
organization. Neither opens a shell.

nerimux reads no configuration file; every key binding and layout value above
is a compiled-in constant.

### Terminal integration

Pasted input is recognized as one bracketed-paste operation. In a pane, the
paste delimiters are preserved only when that pane has requested bracketed
paste; otherwise they are removed before the text reaches the shell (FR-101).
In the command line, tree filter, and picker, pasted line breaks are removed
and the remaining text is inserted into the current field.

Panes that enable terminal focus reporting receive focus-out/focus-in reports
when pane focus changes, and the host terminal's focus changes are relayed to
the focused pane (FR-102).

On attach, the client uses the alternate screen and enables bracketed paste and
focus reporting. Detach, quit, connection loss, and server EOF restore those
terminal modes (FR-103).

Each nerimux-rendered frame is wrapped in synchronized output, `ESC[?2026h`
through `ESC[?2026l`, so the host terminal applies the frame atomically. Pane
PTY bytes and forwarded notifications remain transparent to this framing
(FR-106).

When the focused pane enables DECCKM (`ESC[?1h`), legacy host arrow sequences
`ESC[A` through `ESC[D` are delivered to that pane as `ESC O A` through
`ESC O D`. They remain unchanged when DECCKM is disabled, and modal workspace
input is never sent to a pane (FR-107).

BEL and OSC 9, 99, and 777 notification sequences from panes are forwarded to
attached host terminals even when the pane is not focused. Each pane's
notifications are coalesced to at most one per second; unknown OSC commands
are ignored (FR-104).

A newly attached client passes its allow-listed terminal identity, including
`TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, and `KITTY_*`, to panes created
afterwards. `TERM` remains `screen-256color`; existing panes are unchanged
(FR-108).

The runtime saves worktrees, windows, split layouts, completion state, and
expanded repository rows, then restores them after a server restart. Restored
panes start fresh shells in their worktree, and missing worktrees are skipped
(FR-206).

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

The ordinary suite is the fast regression gate. The strict coverage derivation
is a separate acceptance gate: it currently exposes uncovered runtime paths
and therefore remains red until those paths have tests. Use
`NERIMUX_COVERAGE_REPORT_ONLY=1 nix develop --command sbcl --dynamic-space-size
4096 --no-sysinit --no-userinit --disable-debugger --script
scripts/coverage.lisp /tmp/nerimux-coverage-report` while
investigating; do not weaken the threshold or expand the exclusion list to
hide executable behavior.

## Testing

`nix flake check` runs three derivations in parallel:

| Check | What it covers |
|---|---|
| `default` | the full unit + integration suite (`nerimux/test`) |
| `formatting` | treefmt / nixfmt over every tracked Nix file |
| `docs` | this site, built with `mkdocs --strict` |

The main suite runs on [cl-weave](https://github.com/nerima-lisp/cl-weave) and covers the VT100
emulator, layout geometry, copy mode, and the client/server protocol. The
runner is deliberately sequential because tests share global session/socket state.

Live PTY integration against a real shell is a separate system,
`nerimux/pty-test`, run with `nix run .#test-pty`. It was split out of the
main suite so that `nix flake check` does not imply a result for host PTY work
that cannot run in a sandbox without `/dev/ptmx`; run it yourself when touching
PTY code, because the flake gate does not include it.

There is also an end-to-end smoke script, `tests/e2e/e2e-smoke.lisp`, kept out of
the ASDF test system because it needs a built binary and a real `/dev/ptmx`.
Like `nerimux/pty-test`, it is not part of `nix flake check`; run it
yourself. It first reruns the bounded-process and isolation helper suites as a
regression check, then runs scenarios in a fixed order: kill-without-server,
server-starts, kill-empty-server-succeeds, attach, kill-refuses-with-pane,
kill-force-cleans, and paste. `attach` launches the binary, sends a marker
through the attached pane, verifies the rendered output, and detaches with
`C-q d`:

```bash
nix run .#e2e
```

or, against a manual build:

```bash
nix build .
nerimux-sbcl --script tests/e2e/e2e-smoke.lisp result/bin/nerimux
```

Measured suite runtimes are recorded in [Benchmarks](benchmarks.md).

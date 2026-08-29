# nerimux

A workspace-oriented terminal multiplexer written entirely in Common Lisp,
with a [magit](https://magit.vc/)-style keymap.

A client is always at one of three views — `repolist`, `status`, or `pane` —
over the organization/repository/worktree catalog. A thin client attaches to
a headless runtime over a Unix socket; all key handling, layout, and
rendering happen server-side, so the client itself carries no session state.
There is no standalone in-process mode —
`nerimux attach` and `nerimux server` are the only ways in. Every verified
behavior is pinned by a regression suite that runs hermetically through Nix;
live PTY integration is a separate host check.

Start at [Getting started](getting-started.md) for install, usage, and
default key bindings.

## Workspace UI

- **Repolist** — three sections, Attention (worktrees needing attention or
  holding an exited pane), Active (every other worktree with an open pane),
  and Repositories (collapsed by default; `Tab` expands one). `Tab` on a
  worktree row inline-expands its panes, changed files, and recent commits;
  `?` opens the dispatch transient, whose `k` entry opens a full-screen help
  view listing every binding.
- **Status view** — focus a worktree's staged/unstaged changes and reach
  every git write (commit, push, pull, branch, merge, rebase, stash, fetch,
  tag, reset) through magit-style transient menus. Unread, bell, exit, dirty,
  and conflict signals surface as `!` marks on the repolist tree and global
  picker.
- **Pane view** — a focused shell takes typing directly; every nerimux-level
  key inside it starts with `C-q`, replacing the old normal/input mode
  distinction.
- **Global picker** — press `C-p` to search organizations, repositories,
  worktrees, panes, metadata, and attention items.
- **Thin-client sessions** — `C-q d` detaches one client while the runtime and
  pane processes remain resident for later attach.

## Feature highlights

The workspace UI is the only entry point. It provides:

- **Terminal emulation** — VT100/ANSI with 16/256/true color, alternate
  screen, scroll regions, origin mode, G0–G3 charsets with line-drawing
  remap, DECDHL/DECDWL double-size lines, bracketed paste, SGR mouse,
  OSC 52 clipboard, OSC 133 prompt marks, and UTF-8 with wide (CJK) cells.
- **Scrollback** (`C-q [`, formerly copy mode) — vi-style cursor movement
  (`j`/`k`), scroll to top/bottom (`g`/`G`), begin selection and yank
  (`space`, `y`), and forward/backward search (`/`, `?`, then `n`/`N` to
  repeat).
- **Client/server** — detach/attach over a per-user Unix socket under
  `$TMPDIR` (falling back to `/tmp`), rendering a separate frame per attached
  client from one shared pane layout.

nerimux has no configuration file and no runtime-configurable options: every
value the workspace UI depends on — shell, `$TERM`, scrollback length, split
ratios, pane limits — is a compiled-in constant.

## What it is built on

The runtime is built on SBCL and the `nerima-lisp` sibling libraries for CLI
parsing, PTY and process access, deadlines and concurrency, UTF-8 and regex
handling, terminal rendering, and VCS discovery. The complete dependency map
is in
[Dogfooded sibling libraries](guide/sibling-libraries.md).

The runtime depends only on the nerima-lisp sibling libraries. The test and
coverage systems additionally depend on
[cl-weave](https://github.com/nerima-lisp/cl-weave) 1.3.0. Runtime values such
as the shell, `$TERM`, scrollback length, split ratios, and pane limits are
compiled in; no configuration file is read.

## Project

- Source and issues: <https://github.com/nerima-lisp/nerimux>
- Contribution guide, code of conduct, security policy and support channels
  are the organization-wide files published from
  [nerima-lisp/.github](https://github.com/nerima-lisp/.github).
- Licensed under MIT.

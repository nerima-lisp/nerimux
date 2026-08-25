# Relationship to tmux

nerimux began as a tmux-compatible multiplexer and has since been narrowed to
a **workspace-only** multiplexer (organization → repository → worktree →
window → pane) driven from a thin client attached to a headless server. It no
longer targets behavioral parity with tmux, has no `.tmux.conf`-style config
file at all, and has no tmux-style keystroke or command-name pipeline. This
page states, as of the current tree, what nerimux still shares with tmux at
the implementation level and what was removed outright.

Earlier drafts of this page (and of the working documents that still link
here — `docs/notes/coverage-audit-history.md`,
`docs/notes/workspace-requirements.md`,
`docs/notes/permissions-and-verification.md`) described an intermediate
state, after the tmux command table was deleted but before the config,
options, format, mouse, hooks, and read-only-attach subsystems were removed
in turn. Every claim below was re-checked against the current tree (`grep`
for the cited files and functions) rather than carried forward from those
documents; where a prior claim no longer holds, that is called out
explicitly.

## What still works the way tmux works

Terminal emulation is the one subsystem the workspace narrowing left
essentially untouched. It is not vestigial the way the config/format layers
below are — a real client depends on it every frame.

- **Terminal emulation.** VT100/ANSI parsing and rendering:
  16/256/true-color SGR (including double-underline 21, rapid-blink 26, and
  underline-color 58/59), alternate screen (modes 47/1047/1048/1049),
  scroll regions, origin mode (DECOM), G0–G3 charsets with line-drawing/ACS
  remap, DECSCUSR cursor shape, DECTCEM cursor visibility, bracketed paste
  (mode 2004), focus-event reporting (mode 1004), application cursor keys
  (mode 1), Synchronized Output (mode 2026, accepted and no-op — the
  renderer already composites atomically) and the Kitty keyboard protocol
  (mode 2048, accepted and no-op), DA1/DA2 device attributes, DECRQSS and
  XTGETTCAP over DCS, OSC 7 (cwd) and OSC 8 (hyperlink), OSC 52 clipboard,
  and UTF-8 with wide (CJK) cells and combining characters. Implementation:
  `src/domain/terminal/` (45 top-level files, including `parser-dcs.lisp`,
  `screen.lisp`, `scroll.lisp`, `parser-osc-dispatch.lisp`,
  `modes-dec-pm-definitions.lisp` for the DEC private-mode table).
  Any DEC private mode number not in that table's rule list is accepted and
  silently ignored rather than erroring — this is how the terminal avoids
  choking on modes it does not model (mouse reporting among them; see
  "Removed" below).
- **Copy mode**, but with a smaller and differently-bound key set than
  tmux's. What an attached client can reach today is the fixed `cond` in
  `%handle-client-copy-key-payload`
  (`src/bootstrap/server-multi-dispatch-command-input.lisp:213`): `h`/`j`/`k`/`l`
  to move, `g`/`G` to jump to top/bottom, `Space` to begin a selection, `y`
  to yank, `/` and `?` to open a search prompt with `n`/`N` to repeat, and
  `q` to exit. This is **not** the key set the coverage-audit history
  records (`Esc`/`q` to exit, arrow keys to move) — R4.1 deleted arrow-key
  handling and R4.2 removed `Esc` as a copy-mode exit key, per
  `docs/notes/workspace-requirements.md` §1.5/R4.2, so `q` is now the only
  exit. The implementation kernel these handlers call lives under
  `src/application/commands/copy-mode/` (one file per concern:
  `commands-copy-mode-cursor.lisp`, `commands-copy-mode-selection.lisp`,
  `commands-copy-mode-search.lisp`, `commands-copy-mode-clip.lisp`,
  `commands-copy-mode-virtual.lisp`).
- **Client/server socket model.** A per-user socket directory under
  `$TMPDIR`, falling back to `/tmp` (`$TMUX_TMPDIR` is deliberately not
  read — see "Removed" below), created mode `0700`, with a fixed socket
  name (no `-L`/`-S` override) and stale-socket recovery on startup.
  Detach/attach works with the session persisting on the server, and
  multiple clients may attach at once, sharing a size equal to the smallest
  attached client's terminal. Implementation: `src/bootstrap/server.lisp`
  (`%socket-tmp-base`, `%socket-directory`, `socket-path`, lines 26–55) and
  `src/bootstrap/main-startup-socket.lisp` for stale-socket handling;
  `src/bootstrap/server-multi.lisp:215-242` for the shared-size-is-the-min
  behavior (R8.4).
- **Pane spawning defaults.** Every pane's shell is `$SHELL`, or `/bin/sh`
  if unset (`src/infrastructure/pty/pty.lisp:81-89`), and every pane's child
  process environment is given `TERM=screen-256color` and
  `COLORTERM=truecolor` regardless of the outer terminal
  (`src/domain/model/pane-spawn.lisp:16-18`) — a fixed choice, not a
  `default-terminal` option lookup as it once was.
- **SBCL-specific process model**, unaffected by any of the above removals:
  PTYs are spawned via `cl-tty-kit:make-pty` (`sb-ext:run-program :pty t`
  under the hood — `src/infrastructure/pty/pty.lisp:140-162`) rather than a
  direct `forkpty(3)` call, so the slave path is not exposed the way tmux
  exposes a device path.

## Removed

- **The CLI is `attach`, `server`, and `kill` only.** `nerimux new-session`,
  `has-session`, `kill-server`, `list-sessions`, `list-windows`,
  `list-commands`, `display-message`, `show-options`, `show-window-options`,
  `source-file`, `attach-session`, and every other tmux command name are
  gone as CLI entry points, along with the fallback that used to forward an
  unrecognized word to a running server as a command client. The only
  global flags are `-V`/`--version` and `-h`/`--help`; `-L`, `-S`, `-r`,
  `-2`, `-D`, `-N`, `-l`, `-u`, `-T`, `-c`, `-f`, and `-v` were all deleted
  (R1.17). `nerimux kill [--force]` is new — it is not a tmux command; it
  asks the server to shut down, refusing (exit 1, listing open panes) unless
  `--force` is given, in which case panes are sent `SIGHUP` then `SIGKILL`.
  See `*startup-modes*` in `src/bootstrap/main-startup-commands.lisp:117-128`
  for the exact surviving surface, and `run-kill`
  (`src/bootstrap/main-startup-commands.lisp:55-77`) for the kill semantics.
- **The entire tmux command table and keystroke pipeline are gone.**
  `src/application/dispatch/` and `src/presentation/events/` do not exist
  in the current tree (confirmed by directory absence). No tmux command
  name resolves from any entry point, and no `bind-key`-style key table
  exists — input is dispatched through a small, hardcoded `C-q` prefix
  table instead (`%workspace-prefix-dispatch`,
  `src/bootstrap/server-multi-dispatch-prefix.lisp:286`), not a
  user-configurable one.
- **`server-access` (the read-write/read-only client ACL) no longer
  exists anywhere.** `grep -rn server-access src/` returns nothing. See
  [Server access](#server-access) below and the published
  [security model](security-model.md), which states this as current fact,
  not history.
- **Multi-session support is gone.** The session registry
  (`src/bootstrap/session-registry.lisp`) is now 49 lines holding only
  `server-add-session`/`server-find-session`-style single-session lookups;
  the group-linking machinery (`server-new-session-in-group` and friends)
  that a prior coverage sweep still found is gone along with it. There is
  exactly one session, created once in `run-server`
  (`src/bootstrap/server.lisp:119-133`).
- **Control mode (`-C` / `nerimux control`) is gone.**
  `src/infrastructure/control-mode/` does not exist. `-C` is an
  unrecognized flag.
- **The config file, options, and format-string subsystems are gone in
  their entirety**, not just their dispatch-table callers.
  `src/application/config/`, `src/domain/options/`, and
  `src/domain/format/` do not exist; `grep -rn 'get-option\|expand-format'
  src/` returns nothing. nerimux reads no config file — not `.tmux.conf`,
  not `$NERIMUX_CONF`, not `~/.config/nerimux/nerimux.conf` — and no longer
  reads `$TMUX_TMPDIR` either. See [Config file: what still
  runs](#config-file-what-still-runs).
- **Mouse support is gone**, not merely unwired. `src/presentation/events/`
  (the dispatch/parse layer) doesn't exist, and unlike copy mode it was not
  re-routed: `grep -n mouse src/bootstrap/server-multi-dispatch.lisp` finds
  nothing. The reporting-toggle functions that used to live in
  `renderer-compose-protocols.lisp` were deleted outright (that file's
  header now documents their absence). The DEC private-mode table
  (`modes-dec-pm-definitions.lisp`) has no entries for modes 1000/1002/
  1003/1006 — an app requesting SGR mouse reporting gets silent
  accept-and-ignore (the table's documented behavior for any unlisted mode
  number), not an error and not real reporting.
- **The `domain/hooks/` Lisp-callback hook registry is gone.** `grep -rn
  'hook-registry\|run-hooks\|alert-bell\|alert-activity' src/` returns
  nothing.
- **Alert/activity/bell tracking is gone**, including the mechanism the
  pre-workspace-narrowing version of this page described as "unaffected by
  the dispatch-table removal." `runtime-reader-alerts.lisp` and
  `runtime-timer.lisp` do not exist in the current tree; there is no
  `visual-bell`/`visual-activity` overlay and no window activity/bell/
  silence flags.
- **Read-only attach is gone — not merely unreachable.** A prior sweep
  (recorded in `docs/notes/permissions-and-verification.md`) found the wire
  flag and per-connection enforcement still present but nothing setting the
  flag. That is now further stale: `grep -rn
  'client-read-only\|read-only-p\|attach-flag-read-only' src/` returns
  nothing at all today, and the wire protocol's `msg-attach` payload
  (`src/infrastructure/net/protocol.lisp:23,152-155`) carries only rows and
  columns — no flags byte. There is no way, from any entry point, to attach
  without full read-write pane access. This matches
  [security model: No access control beyond the socket
  boundary](security-model.md#no-access-control-beyond-the-socket-boundary),
  which already states this as current.
- **`detach-others` was never actually wired**, despite being named in a
  docstring. `server.lisp:113`'s message-dispatch docstring still describes
  a `:detach-others` disposition "(the `attach -d` request)", but `grep -rn
  'detach-others\|detach-other' src/` finds only that same docstring line —
  no code path produces or handles the disposition, and there is no `-d`
  attach flag. Treat that docstring line as dead prose, not a live feature.
- **paste-buffer / `add-paste-buffer` is gone.** Clipboard is OSC 52 only:
  copy-mode yank and inbound OSC 52 from a pane both push onto the owning
  screen's `clipboard-queue` and get forwarded to the outer terminal; there
  is no internal paste buffer and no `copy-command`-driven paste-back path.
  Implementation: `src/domain/terminal/parser-osc-clipboard.lisp`,
  `src/application/commands/copy-mode/commands-copy-mode-clip.lisp`.

## Config file: what still runs

There is no config file support left to run. `grep -rn
'\.tmux\.conf\|NERIMUX_CONF\|config-file\|load-config' src/` finds nothing
in the runtime (the one unrelated hit, `posix-port.lisp`, is a comment about
a config-file loader that used to live upstream of a domain constant, not a
loader that exists today). This supersedes the nuanced "still effective /
parsed but inert" split recorded in an earlier state of this page and in
`docs/notes/coverage-audit-history.md`'s Sprint 1/2 "Since removed" notes
— at that point the config *parser* still ran and only its downstream
consumers (key tables, hooks, dispatch) had been deleted. Since then R2.1
deleted the parser and directive layer itself
(`docs/notes/workspace-requirements.md` §R2.1), so the distinction those
notes drew no longer applies to anything: every value that a `.tmux.conf`
directive used to set is now a hardcoded constant, listed in
`docs/notes/workspace-requirements.md` §1.4 (shell, `$TERM`/`COLORTERM`,
scrollback length, split ratio, pane-per-window limit, socket location,
etc.). `docs/src/guide/development-rules.md`'s bug-report checklist already
states this plainly: "There is no config file to include; nerimux reads
none."

## Server access

`docs/notes/permissions-and-verification.md` is a historical record of an
ACL/permissions audit done while `server-access` and the read-only attach
flag still existed in some form. Both are gone now, confirmed by grep
against the current tree (see "Removed" above for the exact commands run).
The current, maintained statement of the access model is
[security model: The socket directory is the security
boundary](security-model.md#the-socket-directory-is-the-security-boundary)
and [security model: No access control beyond the socket
boundary](security-model.md#no-access-control-beyond-the-socket-boundary):
the per-user, mode-`0700` socket directory is the entire boundary, any
client that reaches the socket gets full read-write pane access, and there
is no ACL, role, or read-only mode layered on top of that by nerimux itself.

## Gaps not re-verified in this pass

- `src/application/commands/commands.lisp` (cited by an earlier sweep as
  possibly still holding unreachable `break-pane`/`join-pane`/`move-pane`
  logic) no longer exists — confirmed by file absence. Moot either way for
  a tmux-facing compatibility statement, since none of those tmux command
  names resolve.
- `src/domain/model/window-layout.lisp` (the named-layout algorithms —
  `even-horizontal`, `tiled`, etc.) no longer exists either — confirmed by
  file absence, consistent with splits now being fixed at 50/50
  (`docs/notes/workspace-requirements.md` §1.4). `layout-persistence.lisp`
  (the layout-string encode/decode pair) still exists; whether anything
  still calls it was not checked, and is moot for tmux compatibility since
  `select-layout` does not resolve as a command either way.

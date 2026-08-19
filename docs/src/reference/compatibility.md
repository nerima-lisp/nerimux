# Relationship to tmux

nerimux began as a tmux-compatible multiplexer and has since been narrowed to
a **workspace-only** multiplexer (organization → repository → worktree →
pane) driven from a thin client attached to a headless server. It no longer
targets behavioral parity with tmux. This document states, as of the current
tree, what nerimux still shares with tmux at the implementation level, what
was removed and why, and where a `.tmux.conf` file's directives still take
effect versus where they are silently inert.

A reader diffing against an older revision of this file should read the
"Removed" and "Config file: what still runs" sections as the historical
record — nothing here was deleted by oversight.

## What still works the way tmux works

These subsystems were unaffected by the workspace narrowing and remain
reachable from a live client:

- **Terminal emulation.** VT100/ANSI with 16/256/true color SGR, alternate
  screen, scroll regions, origin mode, G0–G3 charsets with line-drawing
  remap, DECDHL/DECDWL double-size lines (re-emitted to the outer terminal,
  tmux's own strategy), bracketed paste, SGR mouse reporting, OSC 133 prompt
  marks, UTF-8 with wide (CJK) cells, and scrollback with join-aware capture.
  Implementation: `src/domain/terminal/` (34 files, including
  `parser-dcs.lisp`, `screen.lisp`, `scroll.lisp`,
  `parser-osc-dispatch.lisp` for OSC 133).
- **Copy mode**, but a smaller key set than tmux's. What an attached client
  can actually reach is the fixed `cond` in
  `src/bootstrap/server-multi-dispatch.lisp` (`%handle-client-copy-key-payload`):
  `Esc`/`q` to exit, `hjkl` and the arrows to move, `g`/`G` to jump to top and
  bottom, `Space` to begin a selection, `y` to yank, `/` and `?` to search with
  `n`/`N` to repeat. Selection is linear.
  Rectangle selection, word/line/paragraph motions, prompt jumping, incremental
  search and the paste-buffer commands still exist as functions under
  `src/application/commands/copy-mode/`, but nothing binds a key to them now
  that the tmux key tables are gone — they are present and unreachable, in the
  same sense as the inert config directives below.
- **Client/server socket model.** Per-user socket directories under
  `$TMUX_TMPDIR`/`$TMPDIR`/`/tmp`, `-L`/`-S` overrides, mode `0700`
  directories, stale-socket recovery, and detach/attach with the session
  persisting on the server. Implementation:
  `src/bootstrap/server.lisp` (`%socket-tmp-base`, `%socket-directory`,
  `socket-path`, lines 44–77) and `src/bootstrap/main-startup-socket.lisp`
  for stale-socket handling.
- **Format-string engine.** The documented modifier set and format
  variables are still evaluated, and — unlike the config directives below —
  this is not vestigial: the status bar, pane borders, and copy-mode overlay
  genuinely call into it on every render. Implementation:
  `src/domain/format/` (13 files: `format-engine.lisp`,
  `format-modifiers.lisp`, `format-operators.lisp`, etc.), consumed from
  `src/presentation/renderer/renderer-statusbar.lisp`,
  `renderer-borders.lisp`, `renderer-compose.lisp`, and
  `renderer-pane-copy-mode-overlay.lisp`.
- **Pane/window/layout model and alert flags.** Activity/bell/silence
  detection, the sticky bell flag, and the `visual-bell`/`visual-activity`
  overlay messages fire on real PTY output — this is a separate mechanism
  from the config `set-hook` directive discussed below, and it was not
  affected by the dispatch-table removal. Implementation:
  `src/bootstrap/runtime-reader-alerts.lisp` (`%mark-window-activity`,
  `%mark-window-bell`, `%update-window-on-pane-output`).

## Removed

- **The CLI is `attach` and `server` only.** `nerimux new-session`,
  `has-session`, `kill-server`, `list-sessions`, `list-windows`,
  `list-commands`, `display-message`, `show-options`, `show-window-options`,
  `source-file` and `attach-session` are gone, along with the fallback that
  forwarded any other unrecognized word to a running server as a command
  client. `nerimux` with no arguments no longer starts a standalone
  in-process multiplexer; it prints the usage summary and exits non-zero, as
  does any unrecognized command. See `src/bootstrap/main-startup-commands.lisp`
  lines 1–9 for the removal note in-tree, and the `*startup-modes*` table
  (lines 79–91) for the exact surviving surface: `server`, `attach`, `-V`,
  `--version`, `-h`, `--help`.
  - Consequence worth stating: `attach-session -r` was the only way to
    attach read-only from the command line, so that capability is gone. The
    wire protocol still carries the read-only attach flag and the server
    still honours it per connection, but nothing sets it any more.
- **The entire tmux command table is gone.** `src/application/dispatch/`
  (66 files) — every `%cmd-*` handler, the command dispatch tables,
  `dispatch-command`, `%run-command-tokens`, the prefix-key dispatcher — was
  deleted outright. No tmux command name resolves any more, from any entry
  point. This is the reason several `.tmux.conf` directives described below
  now store state that nothing reads.
  - `server-access` went with it. That was the read-write/read-only ACL over
    connected clients, so nerimux now has no per-client authorization layer at
    all — the socket's own permissions are the whole boundary. See the
    [security model](security-model.md).
- **The tmux keystroke pipeline is gone.** `src/presentation/events/`
  (25 files) — the prefix key, key tables, mouse dispatch, and the CPS
  key-stream parser — was deleted. tmux prefix bindings (`C-b c`, etc.) no
  longer exist; `src/presentation/` now contains only `renderer/` and
  `prompt/`.
- **Control mode (`-C` / `nerimux control`) is gone.** It was implemented —
  the `%output`/`%window-pane-changed` notification protocol for
  iTerm2/tmuxp/libtmux-style automation — and was removed deliberately when
  nerimux narrowed to a workspace-oriented multiplexer for a single
  interactive user. `-C` is now an unrecognized flag and exits with the
  usage message rather than being silently accepted.

## Config file: what still runs

`.tmux.conf`-style config files are still parsed. `load-config-file` is
still called during server startup (`src/bootstrap/server.lisp:132`,
`(ignore-errors (load-config-file))`), and the parser/tokenizer/directive
layer under `src/application/config/` (21 files) is otherwise intact: brace
blocks, `\;` sequences, `-a`/`-g`/`-o`/`-w`/`-s` option scopes, `if-shell`,
`run-shell`, `source-file`, `set-environment`, `%if`/`%elif`/`%else`/`%endif`,
`%hidden`, and tmux 3.2 `NAME=value` assignments all still tokenize and
execute as directives.

But the command-table removal above splits what a directive *does* into two
groups, and a directive parsing without error is no longer evidence that it
has an effect:

One trap before the split: the directive **verbs** this parser dispatches are
not all the canonical tmux spellings. `src/application/config/` recognizes
`bind`, `unbind` and `unbind-all` — *not* `bind-key`/`unbind-key` — and
`set-option`, `set-window-option`, `set-session-option` — *not* the `set`
alias. A line using a spelling it does not recognize is dropped silently, so
`set -g default-shell /bin/zsh` does nothing while
`set-option -g default-shell /bin/zsh` works. Note this cuts against the
"canonical names only" rule stated below, which describes the deleted command
parser rather than the config directive parser.

**Still effective** — these `set-option` names have a runtime consumer
outside the config layer, verified by tracing each variable to its reader:

- `default-shell` → `*default-shell*`, read by pane spawning in
  `src/infrastructure/pty/pty.lisp:86-89`.
- `status` (bar visibility/height) → `*status-height*`, read by
  `src/presentation/renderer/renderer-statusbar.lisp` and
  `renderer-compose.lisp`.
- `escape-time` → written into the server-options table
  (`nerimux/options:set-server-option`), which is read wherever server
  options are queried.
- `update-environment` → `nerimux/model:*update-environment*`.

**Parsed but inert** — these directives still update in-memory state, but
nothing reads that state any more because their only consumer lived in the
deleted dispatch/events layers:

- **`bind`/`unbind`.** Still populate `*key-tables*`
  (`src/application/config/config-key-table-store.lisp`), but the only
  reader of `key-table-lookup` left in the tree is the `list-keys`-style
  formatter in `config-listing.lisp`, and nothing calls that formatter from
  a live entry point — the keystroke pipeline that used to consult a
  key-table on every keypress no longer exists. A `bind-key` line in
  `.tmux.conf` now has no observable effect.
- **`set-option prefix`/`prefix2`.** Same story: `%bind-prefix-key` in
  `src/application/config/config-option-side-effects.lisp` writes
  `*prefix-key-code*`/`*prefix2-key-code*` and arms a key-table entry, but
  those variables have no reader outside the config package itself.
- **`set-option mouse`.** Routed through `*mouse-reporting-hook*`
  (declared in `config-directives-macro.lisp`), which is `nil` and never
  assigned anywhere in the tree — the side effect is a guaranteed no-op.
- **`set-hook`.** Directives are stored in `*command-hooks*`
  (`src/domain/hooks/hooks.lisp:128-178`), but firing them requires
  `*command-hook-runner*` (line 210), which the file's own comment says is
  "installed by the nerimux package at load" — and it never is; nothing in
  the tree assigns it. `run-command-hooks-via-runner` (line 215) is
  therefore always a no-op. A `set-hook after-new-window '...'` line parses,
  is stored, and never fires. This is distinct from the internal
  `alert-bell`/`alert-activity` Lisp-callback hooks described above, which
  are unaffected and still fire.

Configs that only use the "still effective" options above behave as
before. Configs that rely on `bind-key`, a custom prefix, `set-option
mouse`, or `set-hook` will load without error and then silently do nothing
for those lines — there is no warning at parse time, because the directive
itself is syntactically valid.

## Intentionally different

- **Canonical command names only.** tmux short aliases (`neww`, `splitw`,
  `killp`, …) were deliberately rejected by the command parser rather than
  kept as a compatibility layer, back when the parser still resolved
  command names at all. This distinction is now moot for interactive use
  since no command name resolves, but the config tokenizer's
  `%known-command-name-p` still distinguishes canonical names from aliases
  when validating `bind-key` targets.
- **SBCL-specific process model.** PTYs are spawned via `cl-tty-kit:make-pty`
  (which uses `sb-ext:run-program :pty t`) rather than `forkpty(3)`, so the
  slave path is not exposed (reported as an empty string where tmux would
  report a device path).

## Known remaining risk

- **Ecosystem fixtures.** Complex status-line configurations (powerline,
  catppuccin, tpm plugins) have not been run as fixtures; the format engine
  covers the documented surface, but untested combinations may expose gaps.
  Note that such configs typically also rely on `bind-key`/`set-hook` for
  plugin wiring, which is now inert per the section above.
- **Soak behavior.** Long-running-session behaviors (history pressure, many
  clients) are covered by unit/integration tests, not by long soak runs.

Bug reports that include what real tmux does in the same situation are the
fastest to act on for the surviving terminal-emulation and copy-mode
surface — see the issue templates. For anything under "Removed" or "Parsed
but inert" above, that comparison no longer applies: the gap is intentional.

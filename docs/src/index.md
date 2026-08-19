# nerimux

A workspace-oriented terminal multiplexer written entirely in Common Lisp.

The primary UI navigates an organization → repository → worktree → pane
workspace. A thin client attaches to a headless runtime, while the existing
tmux-compatible command and server surface remains available during migration.
Every verified behavior is pinned by a regression suite that runs hermetically
through Nix.

Start at [Getting started](getting-started.md), or read the
[compatibility statement](reference/compatibility.md) for the precise account
of what is implemented and what is deliberately different.

## Workspace UI

- **Overview** — navigate the organization → repository → worktree tree and
  inspect pane state in the selected worktree.
- **Detail and attention views** — focus a worktree or collect unread, bell,
  exit, dirty, and conflict signals that need attention.
- **Global picker** — press `C-p` to search organizations, repositories,
  worktrees, panes, metadata, and attention items.
- **Thin-client sessions** — `C-q d` detaches one client while the runtime and
  pane processes remain resident for later attach.

## Compatibility and feature highlights

- **Commands** — every primary command name in tmux's command table resolves
  (~100 commands: `split-window`, `send-keys`, `capture-pane`, `display-menu`,
  `display-popup`, `command-prompt`, `choose-tree`, `if-shell`, …), with
  flag-level behavior closed against upstream tmux across repeated audits.
- **Terminal emulation** — VT100/ANSI with 16/256/true color, alternate
  screen, scroll regions, origin mode, G0–G3 charsets with line-drawing
  remap, DECDHL/DECDWL double-size lines, bracketed paste, SGR mouse,
  OSC 52 clipboard, OSC 133 prompt marks, and UTF-8 with wide (CJK) cells.
- **Copy mode** — vi-style navigation, selection (including rectangle),
  incremental search, prompt jumping, and 90+ `send-keys -X` commands.
- **Format strings** — the full `#{...}` modifier set
  (`b: d: U: L: n: =N: pN: s/// E: t: m: C: a: q: l:`, comparison/boolean
  operators, `W:`/`S:`/`P:` iteration) over 160+ format variables.
- **Options & hooks** — 120+ options across server/session/window/pane
  scopes, 28 hook events with `set-hook` scoping, key tables, and
  `bind-key -N` notes.
- **Client/server** — detach/attach over per-user Unix sockets
  (`-L`/`-S`, `$TMUX_TMPDIR`), multiple sessions, and session groups sharing
  one window set.
- **Configuration** — real `.tmux.conf` syntax: `%if`/`%elif`/`%else`,
  `%hidden`, variable assignments, `source-file`, brace blocks, and tmux
  quoting rules. See [Configuration](guide/configuration.md).

## What it is built on

- **SBCL** — the Lisp implementation (signals via `sb-posix:kill`).
- **cl-tty-kit** — PTY spawn/raw-mode/fd-io, `ioctl` window size, colour
  downsampling, and character display widths.
- **cl-process-kit** — timeout-guarded subprocess run, and `select(2)` over
  raw fds.
- **cl-concurrent-kit** — one reader thread per PTY pane, plus the locks and
  the preemptive `with-timeout` that bound `run-shell` and `pipe-pane`.
- **cl-regex-kit** — regexes (format `s///` and `m/r:` matching).
- **cl-codec-kit** — UTF-8 string↔octet conversion for protocol frames, PTY
  output and OSC payloads.
- **cl-host-kit** — pathname/string host operations.
- **cl-cli** — startup argv/flag parsing.
- **cl-boundary-kit** — the process boundary behind `run-shell`/`if-shell`.
- **cl-parser-kit** — the command-line tokenizer.
- **cl-history-kit** — command-prompt history store and recall.
- **cl-tui-kit** — headless surface rendering, layout and widgets for the
  per-client frames (workspace overview, detail, picker).
- **cl-vcs-kit** — ghq organization/repository/worktree discovery.

Two further siblings are dogfooded in-tree but are **not** in the shipped
binary's dependency closure — they back the optional `nerimux/reasoning` and
`nerimux/dataflow-model` systems, which nothing at runtime calls:

- **cl-prolog-kit** — cold-path relational reasoning over key bindings and the
  command table.
- **cl-dataflow-kit** — the copy-mode lifecycle state machine.

**nerimux has no external dependencies.** Every name above except SBCL is a
`nerima-lisp` sibling. Four external libraries were retired to get here:
**CFFI** and **babel** on 2026-08-01, then **bordeaux-threads** and
**cl-ppcre** on 2026-08-02. Each was replaced by a sibling rather than by
hand-written code.

Two of those removals fixed or changed real behaviour rather than merely moving
it. Dropping the hand-written `ioctl` fixed a bug: it used a fixed prototype for
a variadic syscall, which misfires on the arm64 ABI, so pane resize was a silent
no-op on Apple Silicon. And cl-regex-kit is not a drop-in for cl-ppcre — it is
RE2/Rust-style, with **no backreferences and no lookaround** in patterns. That
is a deliberate trade, and it moves nerimux *closer* to real tmux, which
compiles these same patterns with `regcomp()` + `REG_EXTENDED`, i.e. POSIX ERE,
which has neither construct either. `\1` in a `#{s/…/…/}` **replacement** is
unaffected: that is expanded by the substitution layer, not the engine, in
nerimux exactly as in tmux's own `regsub.c`.

See [Dogfooded sibling libraries](guide/sibling-libraries.md).

## Project

- Source and issues: <https://github.com/nerima-lisp/nerimux>
- Contribution guide, code of conduct, security policy and support channels
  are the organization-wide files published from
  [nerima-lisp/.github](https://github.com/nerima-lisp/.github).
- Licensed under MIT.

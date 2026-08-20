# nerimux

A workspace-oriented terminal multiplexer written entirely in Common Lisp.

The primary UI navigates an organization → repository → worktree → pane
workspace. A thin client attaches to a headless runtime over a Unix socket;
all key handling, layout, and rendering happen server-side, so the client
itself carries no session state. There is no standalone in-process mode —
`nerimux attach` and `nerimux server` are the only ways in. Every verified
behavior is pinned by a regression suite that runs hermetically through Nix.

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

nerimux's tmux-compatible command table, key-table/prefix-key dispatch, and
control mode (`-C`) were removed when the UI became workspace-only; see
[Compatibility](reference/compatibility.md) for the precise, current account
of what an attached client can and cannot do. What remains:

- **Terminal emulation** — VT100/ANSI with 16/256/true color, alternate
  screen, scroll regions, origin mode, G0–G3 charsets with line-drawing
  remap, DECDHL/DECDWL double-size lines, bracketed paste, SGR mouse,
  OSC 52 clipboard, OSC 133 prompt marks, and UTF-8 with wide (CJK) cells.
- **Copy mode** — vi-style cursor movement (`hjkl`/arrows), scroll to top/
  bottom (`g`/`G`), begin selection and yank (`space`, `y`), and forward/
  backward search (`/`, `?`, then `n`/`N` to repeat) — the fixed key set the
  workspace UI's copy-mode handler binds directly, not through `send-keys
  -X`, which no longer has a caller. The word/line/paragraph motions, bracket
  matching and jump-to-character commands that only the tmux key tables reached
  were deleted along with those tables.
- **Format strings** — the `#{...}` modifier engine that renders the status
  bar and pane titles.
- **Options** — options across server/session/window/pane scopes, applied
  live from `.tmux.conf`. Internal hook events still fire around pane and
  client lifecycle (attach, detach, output, exit, new window), but the
  `set-hook` *directive* was removed: firing a stored hook meant running a tmux
  command name, and no command dispatcher exists any more. A `set-hook` line
  parses and is ignored. See
  [Compatibility](reference/compatibility.md).
- **Client/server** — detach/attach over a per-user Unix socket (`-L`/`-S`,
  `$TMUX_TMPDIR`), rendering a separate frame per attached client from one
  shared pane layout.
- **Configuration** — real `.tmux.conf` syntax: `%if`/`%elif`/`%else`,
  `%hidden`, variable assignments, `source-file`, brace blocks, and tmux
  quoting rules apply options and hooks. `bind-key` directives still parse
  but have no runtime effect — there is no key-table dispatch left to read
  them. See [Configuration](guide/configuration.md).

## What it is built on

- **SBCL** — the Lisp implementation (signals via `sb-posix:kill`).
- **cl-tty-kit** — PTY spawn/raw-mode/fd-io, `ioctl` window size, colour
  downsampling, and character display widths.
- **cl-process-kit** — timeout-guarded subprocess run, and `select(2)` over
  raw fds.
- **cl-concurrent-kit** — one reader thread per PTY pane, plus the locks and
  the preemptive `with-timeout` that bounds `pipe-pane`.
- **cl-regex-kit** — regexes (format `s///` and `m/r:` matching).
- **cl-codec-kit** — UTF-8 string↔octet conversion for protocol frames, PTY
  output and OSC payloads.
- **cl-host-kit** — pathname/string host operations.
- **cl-cli** — startup argv/flag parsing.
- **cl-boundary-kit** — the process boundary behind `run-shell`/`if-shell`.
- **cl-parser-kit** — the command-line tokenizer.
- **cl-history-kit** — command-prompt history storage in
  `src/presentation/prompt/` and `bootstrap/runtime-history.lisp`; the
  workspace UI's `:` command line does not currently call it, so this is
  shipped but presently unreached from an attached client.
- **cl-tui-kit** — headless surface rendering, layout and widgets for the
  per-client frames (workspace overview, detail, picker).
- **cl-vcs-kit** — ghq organization/repository/worktree discovery.

One further sibling is dogfooded in-tree but is **not** in the shipped binary's
dependency closure — it backs the optional `nerimux/dataflow-model` system, which
nothing at runtime calls:

- **cl-dataflow-kit** — the copy-mode lifecycle state machine.

A second, **cl-prolog-kit**, backed a `nerimux/reasoning` system that projected
the config key-table store into Prolog facts. That store was deleted once nothing
read it, leaving nothing to project, so the system and its suite were retired.
See [Dogfooded sibling libraries](guide/sibling-libraries.md).

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

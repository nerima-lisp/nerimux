# nerimux

A workspace-oriented terminal multiplexer written entirely in Common Lisp.

The primary UI navigates an organization → repository → worktree → pane
workspace. A thin client attaches to a headless runtime over a Unix socket;
all key handling, layout, and rendering happen server-side, so the client
itself carries no session state. There is no standalone in-process mode —
`nerimux attach` and `nerimux server` are the only ways in. Every verified
behavior is pinned by a regression suite that runs hermetically through Nix.

Start at [Getting started](getting-started.md) for install, usage, and
default key bindings.

## Workspace UI

- **Overview** — navigate the organization → repository → worktree tree and
  inspect pane state in the selected worktree.
- **Detail view** — focus a worktree. There is no separate attention view to
  navigate to any more (the client-facing `:attention` view, its key and its
  widget were deleted); unread, bell, exit, dirty, and conflict signals
  instead surface as `!` marks on the Overview tree and Global picker.
- **Global picker** — press `C-p` to search organizations, repositories,
  worktrees, panes, metadata, and attention items.
- **Thin-client sessions** — `C-q d` detaches one client while the runtime and
  pane processes remain resident for later attach.

## Feature highlights

nerimux's tmux-compatible command table, key-table/prefix-key dispatch, and
control mode (`-C`) are gone; the workspace UI is the only entry point. What
it provides:

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
- **Client/server** — detach/attach over a per-user Unix socket under
  `$TMPDIR` (falling back to `/tmp`), rendering a separate frame per attached
  client from one shared pane layout.

nerimux has no configuration file and no runtime-configurable options: every
value the workspace UI depends on — shell, `$TERM`, scrollback length, split
ratios, pane limits — is a compiled-in constant.

## What it is built on

- **SBCL** — the Lisp implementation (signals via `sb-posix:kill`).
- **cl-tty-kit** — PTY spawn/raw-mode/fd-io, `ioctl` window size, colour
  downsampling, and character display widths.
- **cl-process-kit** — timeout-guarded subprocess run, and `select(2)` over
  raw fds.
- **cl-concurrent-kit** — one reader thread per PTY pane, plus the locks and
  the preemptive `with-timeout` that bounds the PTY child-exit wait. It no
  longer bounds `pipe-pane`, which was deleted; see
  [Dogfooded sibling libraries](guide/sibling-libraries.md).
- **cl-regex-kit** — regexes (format `s///` and `m/r:` matching).
- **cl-codec-kit** — UTF-8 string↔octet conversion for protocol frames, PTY
  output and OSC payloads.
- **cl-host-kit** — pathname/string host operations.
- **cl-cli** — startup argv/flag parsing.
- **cl-boundary-kit** — supplied the process boundary behind `run-shell`/
  `if-shell`, before the configuration system that carried those directives
  was deleted; nothing in `src/` calls into it any more, though `nerimux.asd`
  still lists it as a dependency. See
  [Dogfooded sibling libraries](guide/sibling-libraries.md).
- **cl-parser-kit** — the command-line tokenizer.
- **cl-tui-kit** — headless surface rendering, layout and widgets for the
  per-client frames (workspace overview, detail, picker).
- **cl-vcs-kit** — ghq organization/repository/worktree discovery.

**cl-prolog-kit** backed a `nerimux/reasoning` system that projected the
config key-table store into Prolog facts. That store was deleted once nothing
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

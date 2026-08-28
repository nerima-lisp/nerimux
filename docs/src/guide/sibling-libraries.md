# Dogfooded sibling libraries

nerimux is the organization's L4 application package: nothing depends on it, so
it is where `nerima-lisp` libraries get exercised against a real workload. Each
one below was adopted where it is a genuine fit for something nerimux already
did by hand — not bolted on beside it.

## The other siblings

- [cl-cli](https://github.com/nerima-lisp/cl-cli) parses the top-level
  `nerimux [flags] [command [flags]]` global flags
  (`main-startup-flags.lisp`, `*cli-app*`), replacing the old ad hoc
  `-L`/`-S`-only scanner with real tmux(1) flag parity — flags may now appear
  in any order before the command word.
- [cl-tty-kit](https://github.com/nerima-lisp/cl-tty-kit) backs the PTY layer:
  pane spawn, byte-transparent master-fd read/write, raw mode, and
  terminal-size queries — including the `TIOCSWINSZ` ioctl itself — all
  delegate to it (`src/infrastructure/pty/`). It also contributes
  `rgb-to-256` for true-colour downsampling in `renderer-format.lisp`.
  nerimux keeps its own SIGHUP-based `pty-close` teardown on top, deliberately
  not cl-tty-kit's SIGTERM→SIGKILL escalation, and its own `set-pty-size`
  argument contract (`MASTER-FD ROWS COLS`, transposed from cl-tty-kit's
  `COLUMNS ROWS &optional FD`); the select(2) fd-multiplexing loop below it is
  cl-process-kit's, not nerimux's own.
- [cl-parser-kit](https://github.com/nerima-lisp/cl-parser-kit) is the
  tokenizer framework behind `commands-tokenizer.lisp`'s shell-style argument
  splitter — one custom rule for the quote/escape-joining scan (no generic
  library has tmux's "quotes extend the current argument" grammar built in)
  plus a whitespace-skip rule, composed through
  `cl-parser-kit:tokenize-string`.
- [cl-process-kit](https://github.com/nerima-lisp/cl-process-kit) backs
  `select-fds`/`wait-for-input`, the select(2) fd multiplexing behind the PTY
  reader loop's readiness poll (`select-fds` in
  `src/infrastructure/pty/pty.lisp`, called from `nerimux/pty:select-fds`
  across ~45 sites in `src/` and `t/`). It replaced a hand-rolled select(2)
  wrapper whose `fd-set!` wrote past the end of a 128-byte bitmap for any fd
  past `FD_SETSIZE`, and which read an `EINTR` mid-wait as "nothing ready,"
  silently truncating an infinite-timeout wait on every `SIGWINCH`/`SIGCHLD`.
  It previously also ran nerimux's three "shell out and capture" sites —
  `#{shell-command}` format expansion, the `#{pane_current_*}` OS probes, and
  the copy-mode `copy-command` pipe — but those, and the rest of the
  `#{...}` format-string engine, were deleted with the configuration system;
  `process-kit:run`'s subprocess timeout and SIGTERM→SIGKILL escalation have
  no caller left in nerimux today.
- [cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit) replaced
  `bordeaux-threads` as the threading vocabulary: the per-pane PTY reader
  threads, the screen mutex, the `wait-for` channel's condition variable, the
  VCS worktree-scan thread pool and its fetch lock (`vcs.lisp`), and the
  preemptive `with-timeout` that bounds the PTY child-exit wait
  (`pty-child-exit-status`). Timeout deadlines are
  `cl-date-kit:DURATION` values; the compatibility notes below describe the
  public API.
- [cl-date-kit](https://github.com/nerima-lisp/cl-date-kit) supplies the one
  typed elapsed-time value nerimux currently constructs,
  `duration-of-seconds`, for `+pty-child-wait-timeout+`
  (`src/infrastructure/pty/pty.lisp`), the deadline
  `cl-concurrent-kit:with-timeout` bounds `pty-child-exit-status` with.
- [cl-regex-kit](https://github.com/nerima-lisp/cl-regex-kit) replaced
  `cl-ppcre` behind every regular expression nerimux exposes: copy-mode
  search and its match highlighting (`commands-copy-mode-search.lisp`,
  `renderer-pane-search.lisp`), and the workspace picker's fuzzy/regex query
  matching (`global-picker.lisp`). It originally also backed the `#{m/r:…}`
  match and `#{s/…/…/}` substitute format modifiers (`format-modifiers.lisp`),
  and its `escape` let `copy-mode-search-forward-word`/`-backward-word`
  search literally for the word under the cursor by escaping it before
  handing it to the same regex matcher — both gone, the format engine with
  the configuration system and the word-search commands in the
  workspace-only reduction (`67fe5dc`), so search and the picker are the
  only callers left. This is the one adoption that changed behaviour rather
  than only moving it; the compatibility notes below state the deliberate
  pattern differences from cl-ppcre.
- [cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit) replaced `babel`
  as the UTF-8 string↔octet codec for protocol frames, PTY output and OSC
  payloads (`string-to-octets` / `octets-to-string`). The compatibility notes
  below describe the two decode-behavior differences from babel.
- [cl-host-kit](https://github.com/nerima-lisp/cl-host-kit) supplies
  pathname/string host operations; nerimux's one live call site is
  `host-kit:split-string`, splitting an OSC `rgb:R/G/B` colour spec on `/`
  in `%parse-rgb-color` (`src/domain/terminal/parser-osc-color.lisp`) — a
  fixed single-character delimiter, not a job that needs a compiled
  pattern.
- [cl-tui-kit](https://github.com/nerima-lisp/cl-tui-kit) renders the
  per-client frames — headless surface/backend, layout and widgets behind the
  workspace overview, detail and picker views
  (`src/presentation/renderer/renderer-tui-kit.lisp`).
- [cl-vcs-kit](https://github.com/nerima-lisp/cl-vcs-kit) discovers ghq
  organizations, repositories and worktrees behind the workspace tree
  (`src/infrastructure/vcs/`).

## External dependencies

The runtime entries in `nerimux.asd` name `nerima-lisp` sibling libraries;
SBCL supplies the implementation runtime and POSIX bindings. The test and
coverage systems additionally depend on cl-weave 1.3.0 for declarative tests,
parallel-capable orchestration, and coverage instrumentation.

### Threading and regex compatibility notes

cl-concurrent-kit's
`with-timeout` takes its deadline as a **CL-DATE-KIT:DURATION**, for example
`(cl-date-kit:duration-of-seconds 5)`, and `NIL` means no deadline. This is
different from a bare numeric form. The condition it signals is
`operation-timed-out`, not `timeout`. `sb-ext:timeout` is a
`serious-condition` that is deliberately
*not* an `error`, so a handler written for `error` silently misses it, whereas
`operation-timed-out` inherits from `cl-concurrent-kit-error`.

cl-regex-kit patterns intentionally differ from cl-ppcre:

- **No backreferences and no lookaround in patterns.** cl-regex-kit is
  RE2/Rust-style by design. `([a-z]+)_\1` and `(?=…)`/`(?<=…)` are rejected with
  a `regex-syntax-error` rather than mis-compiled — the same restriction
  `%copy-mode-make-matcher` (`commands-copy-mode-search.lisp`) and
  `%picker-regex-scanner` (`global-picker.lisp`) both compile under today.
- **This originally moved nerimux closer to real tmux, not further away.**
  When cl-regex-kit backed the (now-deleted) `#{m/r:…}`/`#{s/…/…/}` format
  modifiers, upstream compiled those same patterns with `regcomp()` +
  `REG_EXTENDED` (`format.c`, `regsub.c`) — POSIX ERE, which has no
  backreferences and no lookaround either, so the RE2-style rejection was not
  a portability regression against a GNU-only `\1` extension tmux itself
  could not rely on. `format-modifiers.lisp` and the rest of
  `src/domain/format/` are gone with the configuration system, so this
  comparison is historical; the restriction now surfaces only through
  copy-mode search and the picker's regex query, neither of which offers
  substitution, so upstream's separate `\N`-in-replacement handling
  (`regsub_expand()` vs `regcomp()`) has no nerimux call site to compare
  against anymore.
- **Invalid patterns degrade rather than crash.** `%copy-mode-make-matcher`
  and the pane-search highlighter (`renderer-pane-search.lisp`) both catch
  `regex-syntax-error` and fall back to a literal substring search.
  `%picker-regex-scanner` catches the same condition and returns `NIL`, so
  `filter-global-picker-items` matches nothing under an invalid regex query
  rather than signalling.

One user-visible tightening came with it: `%parse-rgb-color` no longer accepts a
malformed `rgb:R/G/B/` with a trailing delimiter. `cl-ppcre:split` dropped
trailing empty fields, so that string split into exactly three parts and parsed;
the plain character split that replaced it keeps them, and xterm's `rgb:` syntax
is exactly three channels.

### Host and codec compatibility notes

`select(2)` and raw descriptor operations are provided by cl-process-kit
(`select-fds` / `wait-for-input`) and cl-tty-kit (`set-terminal-size`,
`fd-read-octets`, `fd-write-octets`). POSIX process signalling uses
`sb-posix:kill`. Three observable guarantees matter:

- **A live bug was fixed.** nerimux called variadic `ioctl(TIOCSWINSZ)` through
  a *fixed* CFFI prototype. On the arm64 ABI a variadic argument is passed on
  the stack while a fixed prototype passes it in a register, so the call failed
  with `EFAULT` — `set-pty-size` was a silent no-op on Apple Silicon, and child
  processes never learned their window size. cl-tty-kit goes through
  `sb-unix:unix-ioctl`, which marshals the pointer correctly.
- **`EINTR` is retried** against a deadline fixed up front, so a `SIGWINCH` or
  `SIGCHLD` landing mid-`select` no longer reads as a spurious "nothing ready".
- **`fd >= FD_SETSIZE` is rejected** with `fd-set-overflow`. nerimux's own
  `fd-set!` wrote past the end of the 128-byte bitmap with no bounds check.

UTF-8 string↔octet conversion uses
[cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit)'s
`string-to-octets` / `octets-to-string` — a from-scratch, babel-API-compatible
codec with `:depends-on ()`, which cl-tty-kit and cl-process-kit already use.
The API keeps the same keyword shape (`:encoding`, `:start`, `:end`, `:errorp`)
where callers need it; cl-host-kit remains limited to host/pathname helpers.

Two behaviors are worth knowing:

- **Lone surrogates.** babel silently encoded them CESU-8 style; cl-codec-kit
  signals (`surrogate-code-point`). nerimux's own UTF-8 decoder could produce
  one — the bytes `ED A0 80` from a child process reassemble to U+D800 — and
  `char-code-limit` does not exclude the surrogate block, so it reached a
  screen cell and then the frame encoder. `safe-code-char` substitutes U+FFFD
  for D800–DFFF, which is what a terminal should display for an unpaired
  surrogate regardless.
- **U+FFFD count.** babel emitted one replacement character per malformed
  *sequence*. cl-codec-kit emits one per decode error and then resyncs one
  octet at a time, so `C0 AF` yields two and `ED A0 80` yields three. This only
  affects the OSC payload decode, whose result is split on the first `;` and
  passed on as opaque text, so no length arithmetic depends on it.

The replacement character is passed **explicitly** at that one lenient call
site. cl-codec-kit's own default is `#\SUB` (U+001A), a C0 control character;
babel's UTF-8 decoder hardcoded U+FFFD. nerimux wants U+FFFD — it is what babel
did, and it is what `safe-code-char` already substitutes everywhere else.

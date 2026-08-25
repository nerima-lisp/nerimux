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
  terminal-size queries all delegate to it (`src/infrastructure/pty/`). It also
  contributes `rgb-to-256` for true-colour downsampling in
  `renderer-format.lisp`. nerimux keeps its own `select(2)`
  fd-multiplexing loop, SIGHUP `pty-close`, and `set-pty-size` ioctl on top.
- [cl-parser-kit](https://github.com/nerima-lisp/cl-parser-kit) is the
  tokenizer framework behind `commands-tokenizer.lisp`'s shell-style argument
  splitter — one custom rule for the quote/escape-joining scan (no generic
  library has tmux's "quotes extend the current argument" grammar built in)
  plus a whitespace-skip rule, composed through
  `cl-parser-kit:tokenize-string`.
- [cl-process-kit](https://github.com/nerima-lisp/cl-process-kit) is the
  timeout-guarded subprocess runner the three direct "shell out and capture"
  sites call: `#(shell-command)` format expansion, the `#{pane_current_*}` OS
  probes, and the copy-mode `copy-command` pipe. `process-kit:run` escalates
  SIGTERM→SIGKILL over the child's process group on a deadline overrun, so a
  hung command never orphans a shell.
- [cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit) replaced
  `bordeaux-threads` as the threading vocabulary: the per-pane PTY reader
  threads, the screen mutex, the `wait-for` channel's condition variable, the
  VCS worktree-scan thread pool and its fetch lock (`vcs.lisp`), and the
  preemptive `with-timeout` that bounds the PTY child-exit wait
  (`pty-child-exit-status`). Timeout deadlines are
  `cl-date-kit:DURATION` values; the compatibility notes below describe the
  public API.
- [cl-date-kit](https://github.com/nerima-lisp/cl-date-kit) supplies those
  typed elapsed-time values, such as `duration-of-millis` and
  `duration-of-seconds`, to `cl-concurrent-kit:with-timeout`.
- [cl-regex-kit](https://github.com/nerima-lisp/cl-regex-kit) replaced
  `cl-ppcre` behind every regular expression nerimux exposes: the `#{m/r:…}`
  match and `#{s/…/…/}` substitute format modifiers (`format-modifiers.lisp`),
  copy-mode search and its match highlighting
  (`commands-copy-mode-search.lisp`, `renderer-pane-search.lisp`), and the
  workspace picker's fuzzy/regex query matching (`global-picker.lisp`). Its
  `escape` also subsumed a hand-rolled metacharacter escaper in
  `commands-copy-mode-search.lisp`. This is the one adoption that changes
  behaviour rather than only moving it; the compatibility notes below state
  the deliberate pattern differences from cl-ppcre.
- [cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit) replaced `babel`
  as the UTF-8 string↔octet codec for protocol frames, PTY output and OSC
  payloads (`string-to-octets` / `octets-to-string`). The compatibility notes
  below describe the two decode-behavior differences from babel.
- [cl-host-kit](https://github.com/nerima-lisp/cl-host-kit) supplies
  pathname/string host operations — `split-string` and the directory helpers.
- [cl-tui-kit](https://github.com/nerima-lisp/cl-tui-kit) renders the
  per-client frames — headless surface/backend, layout and widgets behind the
  workspace overview, detail and picker views
  (`src/presentation/renderer/renderer-tui-kit.lisp`).
- [cl-vcs-kit](https://github.com/nerima-lisp/cl-vcs-kit) discovers ghq
  organizations, repositories and worktrees behind the workspace tree
  (`src/infrastructure/vcs/`).

## External dependencies

nerimux has no external dependencies. Every entry in `nerimux.asd`'s
`:depends-on` names a `nerima-lisp` sibling; SBCL supplies the implementation
runtime and POSIX bindings.

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
  a `regex-syntax-error` rather than mis-compiled.
- **This moves nerimux closer to real tmux, not further away.** Upstream
  compiles `#{m/r:…}` and `#{s/…/…/}` patterns with `regcomp()` +
  `REG_EXTENDED` (`format.c`, `regsub.c`) — POSIX ERE, which has no
  backreferences and no lookaround either. Under glibc a pattern-side `\1` may
  happen to work as a GNU extension; on the BSDs and macOS it does not, so
  anything relying on it was already non-portable in tmux itself.
- **`\N` in a *replacement* is unaffected.** `#{s/a(.)/\1x/i:}` still turns
  `abABab` into `bxBxbx`, exactly as `tmux(1)` documents. That `\1` is expanded
  by the substitution layer, never handed to the regex engine — the same split
  upstream has between `regsub_expand()` and `regcomp()`.
- **Invalid patterns still degrade rather than crash.** `#{m/r:}` returns `0`
  and `#{s///}` returns the string unchanged, which is what upstream's
  `format_match()` does on a `regcomp` failure. Copy-mode search and its
  highlighting both fall back to a literal substring search.

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

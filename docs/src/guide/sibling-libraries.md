# Dogfooded sibling libraries

nerimux is the organization's L4 application package: nothing depends on it, so
it is where `nerima-lisp` libraries get exercised against a real workload. Each
one below was adopted where it is a genuine fit for something nerimux already
did by hand — not bolted on beside it.

## Retired: cold-path reasoning with cl-prolog-kit

`src/reasoning/` was a declarative read-model built on
[cl-prolog-kit](https://github.com/nerima-lisp/cl-prolog-kit), a dependency-free
Common Lisp Prolog engine. It shipped as the optional `nerimux/reasoning` system
with its own cl-weave suite (`nerimux/weave`) and flake check. **Both are gone.**

It projected nerimux's declarative tables into Prolog rulebases so relational
questions could be asked of them — which keys run a command, which bindings
conflict across tables. That was a real fit while those tables existed. It no
longer has anything to project, and the two domains it carried died for
instructively different reasons.

**The command domain died silently.** `command-rulebase.lisp` projected the tmux
command table into a rulebase behind `current-command-rulebase`,
`command-accepts-flag-p`, `commands-with-flag`, `flags-of-command`,
`scriptable-commands`, `command-usage-facts` and `build-command-rulebase`.
Deleting the table it projected (`src/application/dispatch/`) did not break it
outright — the projection reached the table's data through `find-symbol`, an
edge no compiler tracks, so the lookup returned `NIL` and the rulebase built
itself over zero facts. Every query would have gone on returning empty answers
forever. The regression suite is what caught it, because it asserted concrete
facts rather than mere non-emptiness.

**The key domain died loudly**, and that is the better failure. `key-rulebase.lisp`
and `key-tables.lisp` referenced `nerimux/config:*key-tables*`, `+table-root+` and
the `key-table-*` accessors with ordinary package-qualified references. When the
key-table store was deleted — nothing on a live path had read it since the
keystroke pipeline went — the system stopped loading at once, with
`no symbol named "KEY-DISPLAY-STRING" in "NERIMUX/CONFIG"`. A hard compile error
is strictly better than a silent empty rulebase, and the contrast is the whole
lesson: `find-symbol` buys loose coupling by discarding the compiler's ability to
tell you the thing is gone.

With no facts left to project there was nothing to narrow the system to, so
`nerimux/reasoning`, `t/weave/`, both `defsystem` forms and the `weave` flake
check were removed together. This was deliberate. Do not reintroduce them unless
something declarative comes back that is worth reasoning over relationally.

## The other siblings

- [cl-cli](https://github.com/nerima-lisp/cl-cli) parses the top-level
  `nerimux [flags] [command [flags]]` global flags
  (`main-startup-flags.lisp`, `*cli-app*`), replacing the old ad hoc
  `-L`/`-S`-only scanner with real tmux(1) flag parity — flags may now appear
  in any order before the command word.
- [cl-boundary-kit](https://github.com/nerima-lisp/cl-boundary-kit) supplies
  the process boundary (`nerimux/config:*process-boundary*`) that the
  `run-shell` / `if-shell` config directives — and the other config-time shell
  directives — run through, so tests can swap in a fake process without shelling
  out for real.  There is no non-directive form of those two any more.
- [cl-dataflow-kit](https://github.com/nerima-lisp/cl-dataflow-kit) models the
  copy-mode lifecycle as an inspectable state machine (`src/dataflow/`), the
  cl-dataflow-kit counterpart to `src/reasoning/` above — same cold-path-only rule,
  same dedicated flake check (`dataflow`), and likewise an optional system
  (`nerimux/dataflow-model`) rather than part of the shipped binary.
- [cl-tty-kit](https://github.com/nerima-lisp/cl-tty-kit) backs the PTY layer:
  pane spawn, byte-transparent master-fd read/write, raw mode, and
  terminal-size queries all delegate to it (`src/infrastructure/pty/`). It also
  contributes `rgb-to-256` for `-2` (force-256-colour) true-colour
  downsampling in `renderer-format.lisp`, nerimux's first outer-terminal
  colour-capability negotiation. nerimux keeps its own `select(2)`
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
  hung command never orphans a shell. `run-shell` / `if-shell` deliberately
  stay on cl-boundary-kit, which supplies the injectable test double
  (`make-test-process-boundary`) that cl-process-kit has no equivalent for.
- [cl-history-kit](https://github.com/nerima-lisp/cl-history-kit) replaced the
  hand-rolled list-and-cursor walk behind the prompt subsystem's Up/Down
  recall (`runtime-history.lisp`, `prompt.lisp`). Storage, capacity, and
  navigation are now cl-history-kit's: `history-add`/`history-entries` for the
  store, `history-merge` to carry entries across a capacity change when
  `prompt-history-limit` is set at runtime, and `history-previous`/
  `history-next` for recall. This is a deliberate behavior change from real
  tmux: cl-history-kit's recall is **prefix-filtered** (the buffer at the
  start of a walk becomes both its match filter and its restore origin,
  zsh-style), where tmux's own Up/Down is an unfiltered raw walk. Chosen for
  the better editing ergonomics over strict Up/Down parity. The tmux
  `:command-prompt` command this was originally written for lost its handler
  along with the rest of `src/application/dispatch/`; the prompt/history
  machinery survives because copy-mode search (`commands-copy-mode-search.lisp`)
  opens the same prompt for its own query input.
- [cl-concurrent-kit](https://github.com/nerima-lisp/cl-concurrent-kit) replaced
  `bordeaux-threads` as the threading vocabulary: the per-pane PTY reader
  threads and the config-time background `run-shell`, the screen mutex, the
  `wait-for` channel's condition variable, and the
  preemptive `with-timeout` that bounds `pipe-pane` and the PTY child-exit
  wait.  It no longer bounds `run-shell`: that wrapper lived in the deleted
  commands-shell.lisp, and the surviving config directive bounds itself through
  cl-boundary-kit's own `:timeout` instead. See the retirement note below for the two API differences
  that matter when reading pre-migration code.
- [cl-regex-kit](https://github.com/nerima-lisp/cl-regex-kit) replaced
  `cl-ppcre` behind every regular expression nerimux exposes: the `#{m/r:…}`
  match and `#{s/…/…/}` substitute format modifiers (`format-modifiers.lisp`),
  copy-mode search and its match highlighting
  (`commands-copy-mode-search.lisp`, `renderer-pane-search.lisp`), and the
  workspace picker's fuzzy/regex query matching (`global-picker.lisp`). Its
  `escape` also subsumed a hand-rolled metacharacter escaper in
  `commands-copy-mode-search.lisp`. This is the one adoption that changes
  behaviour rather than only moving it; the retirement note below states
  exactly how. (The tmux `list-commands -F` placeholder expansion this
  section used to cite is gone along with `list-commands`'s handler — see
  the command-rulebase retirement note above for the same underlying
  removal.)
- [cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit) replaced `babel`
  as the UTF-8 string↔octet codec for protocol frames, PTY output and OSC
  payloads (`string-to-octets` / `octets-to-string`). See the retirement note
  below for the two decode-behavior differences from babel.
- [cl-host-kit](https://github.com/nerima-lisp/cl-host-kit) supplies
  pathname/string host operations — `split-string` and the directory helpers.
  It briefly carried the codec call sites too, for one day during the `babel`
  retirement, before they were re-pointed at cl-codec-kit directly.
- [cl-tui-kit](https://github.com/nerima-lisp/cl-tui-kit) renders the
  per-client frames — headless surface/backend, layout and widgets behind the
  workspace overview, detail and picker views
  (`src/presentation/renderer/renderer-tui-kit.lisp`).
- [cl-vcs-kit](https://github.com/nerima-lisp/cl-vcs-kit) discovers ghq
  organizations, repositories and worktrees behind the workspace tree
  (`src/infrastructure/vcs/`).

## External dependencies

**There are none.** nerimux was the last `nerima-lisp` repository with any, and
as of 2026-08-02 every name in `nerimux.asd`'s `:depends-on` is an org sibling.

The list was four at the start of the 2026-08-01 sweep. Each removal replaced an
external library with an org sibling rather than with hand-written code, which is
the outcome the dependency policy is aiming for.

### Retired: `bordeaux-threads` and `cl-ppcre`

`bordeaux-threads` became **cl-concurrent-kit**. Portability was the entire
point of bordeaux-threads, and ADR-0048 makes the org SBCL-only, so it was
buying nothing that `sb-thread` did not already provide. One syntactic
difference is worth knowing if you are reading old code: cl-concurrent-kit's
`with-timeout` takes its deadline as a **bare form**, like `sb-ext:with-timeout`
— `(with-timeout 5 …)`, not bordeaux-threads' `(with-timeout (5) …)` — and the
condition it signals is `operation-timed-out`, not `timeout`. The rename is an
improvement: `sb-ext:timeout` is a `serious-condition` that is deliberately
*not* an `error`, so a handler written for `error` silently misses it, whereas
`operation-timed-out` inherits from `cl-concurrent-kit-error`.

Removing it also let a dead `#-sbcl` polling branch go from
`%join-thread-with-timeout`, which had been incoherent anyway: the `#+sbcl`
half of the same function already made it SBCL-only in practice.

`cl-ppcre` became **cl-regex-kit**. This is the one removal that is **not
behaviour-preserving**, and the difference is worth stating plainly:

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

### Retired: `cffi` and `babel`

`cffi` covered `select(2)`, `ioctl(2)`, and raw `read`/`write`. Those moved to
cl-process-kit (`select-fds` / `wait-for-input`), cl-tty-kit
(`set-terminal-size`, `fd-read-octets`, `fd-write-octets`) and `sb-posix`
(`kill`). Three things improved rather than merely moving:

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

`babel` covered UTF-8 string↔octet conversion, now
[cl-codec-kit](https://github.com/nerima-lisp/cl-codec-kit)'s
`string-to-octets` / `octets-to-string` — a from-scratch, babel-API-compatible
codec with `:depends-on ()`, which cl-tty-kit and cl-process-kit already use.
The API deliberately keeps babel's keyword shape (`:encoding`, `:start`,
`:end`, `:errorp`), so 70 of the 71 call sites were a package rename.

These sites went through cl-host-kit's `string-to-octets` /
`octets-to-string` for one day (2026-08-01) before being re-pointed at
cl-codec-kit on 2026-08-02, so that the codec is named at its own call sites
rather than behind a host-operations package. cl-host-kit remains a dependency
for `split-string` and the pathname helpers.

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

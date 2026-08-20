# Architecture

nerimux is workspace-only: there is no in-process standalone multiplexer.
Every session is owned by a headless `nerimux server`, and a thin
`nerimux attach` client renders whatever the server sends it. The two talk
over a length-prefixed frame protocol on a Unix socket
(`src/infrastructure/net/protocol.lisp`, `transport.lisp`).

## Event flow

```
client (nerimux attach)                       server (nerimux server)
────────────────────────                      ────────────────────────────────────
stdin, raw mode                                %multi-serve-iteration, one per tick:
  │                                              1. %broadcast-frame when *dirty*
  ▼                                              2. select() listener fd + every
%forward-stdin-byte                                 client fd (+poll-timeout-us+)
  │  +msg-key+ frame                              3. accept a new connection
  ▼                                              4. dispatch one message per
SIGWINCH ──► %maybe-send-resize                     ready client
  │  +msg-resize+ frame
  ▼                                                            │
   length-prefixed frame, Unix socket ───────────────────────► ▼
                                              %handle-multi-client-message
                                              (per-client CLIENT-CONN: its own
                                               rows/cols, view, mode, focus)
                                                            │
                       ┌────────────────────────────────────┼───────────────────────┐
                       ▼                                    ▼                        ▼
              workspace UI handlers                 focused pane's PTY      +msg-command+ payload
              (per-CLIENT-CONN mode:                 (:input mode only —    → %handle-client-ui-command
               :normal/:picker/:command/:copy —        pty-write via the      (workspace UI vocabulary:
               overview/detail/attention nav,           *write-pty* port)      wt-create, tree-*, picker-*,
               wt-create/wt-delete, copy-mode nav)                             attention-*, mode, focus …)
                                                            ▲
                                                            │ pane-feed, screen update, *dirty* = T
                                              ┌─────────────┴──────────────┐
                                              │ reader thread (one per     │
                                              │ live pane): blocking       │
                                              │ read(pane fd) → pane-feed  │
                                              │ → screen-process-bytes     │
                                              └────────────────────────────┘
                                                            │
   client stdout ◄─────────────────────────────────────────┘
     %receive-server-frame                    %render-client-frame (per client, at
     writes +msg-frame+ payload                that client's own rows×cols):
     straight to *standard-output*               render-workspace-overview-to-tui-string /
                                                  render-workspace-attention-to-tui-string /
                                                  render-session-to-tui-string
                                                → +msg-frame+ frame back to that client
```

The client holds no session state at all — no prefix key, no key tables, no
per-window layout. It puts stdin in raw mode, forwards every byte as a
`+msg-key+` frame, forwards a `+msg-resize+` frame when `SIGWINCH` fires, and
writes back whatever `+msg-frame+` payload the server sends
(`src/bootstrap/client.lisp`). All key handling, mode transitions, and
rendering happen server-side, keyed off the per-connection `CLIENT-CONN`
struct in `src/bootstrap/server-multi.lisp`.

The server renders **per client**, not once for the whole session: each
attached `CLIENT-CONN` can be at a different view (overview/detail/attention),
a different UI mode, and a different terminal size, so `%render-client-frame`
(`src/bootstrap/server-multi.lisp`) picks the matching renderer and the
client's own `rows`/`cols` on every broadcast. The shared pane/PTY layout
underneath is still sized once, from the `window-size` option applied across
all attached clients (`%effective-client-size`).

A key an attached client sends only reaches a pane's PTY through `:input`
mode (`i` from `:normal`, or a `split-window -I` stdin target). There is no
prefix-key or key-table fallthrough from `:normal` mode any more — that
pipeline (`application/dispatch/`, `presentation/events/`) was removed with
the standalone multiplexer, and `%handle-multi-key-message`
(`src/bootstrap/server-multi-dispatch.lisp`) says so directly at the point
where the fallthrough used to be. The key-table store a `.tmux.conf` `bind`
directive used to write into is gone too: nothing had read it since the
dispatch layer went, so it was deleted rather than kept as write-only state.
A `bind` line now matches no handler at all and is silently dropped.

## Layering

The layering rule is:

- `domain` defines the session/window/pane model and, in `domain/ports/`, the
  capabilities it needs from outside itself. It is not I/O-free, and the
  distinction it draws is between two kinds of outside capability.

  A capability with a second implementation that tests genuinely exercise is a
  port **variable**: `nerimux/ports:*spawn-pty*`, `*write-pty*` and friends,
  bound at server startup by `install-pty-port` (`src/bootstrap/server.lisp`)
  and bound to a fake by the PTY tests.

  A capability with exactly one implementation is a plain **wrapper**:
  `environment-value`, `environment-entries`, `working-directory` in
  `posix-port.lisp`. Their tests stub by setting a real environment variable,
  never by installing a fake, so a port variable would have nothing on the other
  side — and an unbound one would reproduce this codebase's most repeated
  failure, a port nobody installs whose fallback succeeds silently. The wrappers
  still earn their place by naming the dependency in one file instead of
  scattering raw `sb-ext:` calls through `domain/model/` and `domain/format/`.

  Git is neither: it does not go through `domain` at all. `bootstrap` calls the
  `nerimux/vcs` infrastructure package directly (`workspace-organizations`,
  `refresh-workspace-organizations-async`, …), which is legal because bootstrap
  sits above every layer.
- `application` holds use cases over the domain model: what is left in
  `commands/` (copy mode, the command-line tokenizer, pipe-pane, and pane PTY
  teardown), and `.tmux.conf` directive parsing in `config/`.
- `infrastructure` provides the real PTY/socket/VCS adapters and binds the
  domain's port variables to them.
- `presentation` turns model state into escape codes and, for the workspace
  UI, into `cl-tui-kit` surfaces.
- `bootstrap` is the top of the graph: the entry point, the client and server
  event loops, and the per-client dispatch that ties the layers below
  together. Nothing below it may depend on it.

Below `domain` sits one thing that is not a layer so much as a floor:
`nerimux/text` (`src/domain/text/`), string-to-value coercions with no nerimux
dependency at all. ASDF loads it first and anything may call it.

That rule is enforced by two tests in
`t/unit/bootstrap/system-composition-tests.lisp`, which exist because each
catches what the other cannot.

`no-package-declares-an-upward-layer-dependency` reads every `defpackage` form
and fails if one declares an upward `:use` or `:import-from`. It catches a
package re-opening the hole wholesale — a `:use` clause makes every reference
through it *unqualified*, and therefore invisible to a search for the package
name.

That check has a blind spot it cannot close by construction: a reference written
`nerimux::%some-helper` appears in no `defpackage` form, so nothing declares it,
and `::` bypasses the export list too. So the second test,
`no-source-file-references-a-higher-layer-package`, scans source text instead: it
strips comments, strings and character literals, maps every `pkg:sym` and
`pkg::sym` reference to the referenced package's layer, and fails on any that
points upward. Direction is what it judges — using `::` to reach *downward* is an
export-hygiene question, not a layering one.

It also fails when a `nerimux/…` package carries no layer marker in its
`defpackage` docstring. That case is currently empty and kept deliberately: a
package nothing classifies is a package silently exempt from the check, the same
shape of hole as the one above. Neither test carries an allow-list, for the same
reason — an exception list makes a guard green while preserving exactly the
condition it exists to find.

Two things are worth knowing before either test is next read as red:

- **An upward reference and a wrong layer label produce the identical failure.**
  The first run of the source scan reported three violations against
  `nerimux/version`, which had labelled itself BOOTSTRAP while depending on
  nothing, loading first, and returning a constant. The callers were fine; the
  label was wrong. Check the label first.
- **A violation does not imply a missing port.** The four found this way were
  fixed four different ways: moving the code down to the foundation package,
  calling the library the wrapper already delegated to, inverting the dependency
  into an injected hook, and deleting the feature outright because nothing
  assigned its flag. Pick by which the case actually is.

Terminal code separates data (`types`) from logic (`actions`, `csi`, `sgr`, the
CPS parser) one level further down.

## Source layout

`src/` is nested rather than flat — the one place nerimux deviates from the
organization's package standard, and a deliberate exception: past a certain
file count (`find src -name '*.lisp' | wc -l` for today's number) a flat
directory stops being navigable. Package definitions are correspondingly
split across several `src/bootstrap/package-*.lisp` fragments loaded by
`src/bootstrap/package.lisp`.

`application/dispatch/` (the tmux command table and prefix-key dispatcher)
and `presentation/events/` (the tmux keystroke pipeline: prefix key, key
tables, mouse dispatch) are gone — removed along with the standalone
multiplexer entry point. Their one surviving call site,
`%cmd-new-window`, was rebuilt directly in `bootstrap/` as
`workspace-window.lisp`, sized for the workspace UI instead of `new-window`'s
five tmux-only flags. `infrastructure/control-mode/` (the `-C` control-mode
REPL) is gone too.

```
nerimux/
├── flake.nix               # Nix build + checks (pure Lisp, no C compilation)
├── nerimux.asd             # ASDF systems: nerimux, /test, /dataflow,
│                           #   plus optional /dataflow-model
├── run-tests.lisp          # single Lisp-level test entry point
├── src/
│   ├── bootstrap/          # packages, entry point (`attach`/`server`), the
│   │                       #   client and server event loops, session registry
│   ├── domain/             # pure model + logic (no I/O)
│   │   ├── terminal/       #   VT100/ANSI emulator (data structs ⁄ logic split)
│   │   ├── model/          #   session → window → pane tree, layouts
│   │   ├── format/         #   #{...} format-string engine
│   │   ├── options/        #   option registry + scopes
│   │   ├── hooks/          #   hook registry + firing
│   │   ├── buffer/         #   paste buffers
│   │   ├── persistence/    #   runtime-snapshot struct (detach/attach state)
│   │   └── ports/          #   the PTY port variables, plus the posix wrappers
│   ├── application/        # use cases over the domain model
│   │   ├── commands/       #   copy-mode, the command-line tokenizer and
│   │   │   └── copy-mode/  #     pipe-pane — what outlived the command table
│   │   ├── config/         #   tmux.conf directive parsing: options, hooks,
│   │   │                   #   source-file, run/if-shell (bind/unbind parse
│   │   │                   #   and are discarded — see note above)
│   │   └── picker/         #   global picker item model (build/filter across
│   │                       #   the workspace catalog)
│   ├── infrastructure/     # adapters: PTY, sockets, raw-mode stdin input, VCS
│   ├── presentation/       # renderer, prompt/overlay
│   │   ├── prompt/         #   command-prompt overlay rendering
│   │   └── renderer/       #   pane compositor + workspace views + cl-tui-kit — see
│   │                       #   below, it is one render path, not two
│   └── dataflow/           # cl-dataflow-kit cold-path read-model — OPTIONAL system
└── t/
    ├── unit/               # feature-focused spec files
    ├── integration/        # PTY/socket/runtime integration specs
    ├── dataflow/           # cl-weave suite for the copy-mode lifecycle read-model
    └── e2e/                # binary-level smoke test
```

Every client-facing frame is built in two passes: an ANSI-producing pass, then
`renderer-tui-kit.lisp` replaying that frame into a `cl-tui-kit` surface to
layer widgets (the picker modal, the workspace tree) on top.

There are **two independent first passes**, and the split is deliberate:

- **The pane view** — `render-session-to-string` (`renderer-compose.lisp`),
  reading status-bar options, laying out panes and emitting escape codes. This
  is the VT100 machinery: pane and border rendering, status-bar composition,
  style/SGR emission, copy-mode overlays. Fifteen files, exercised on every
  frame that shows terminal content.
- **The workspace views** — `render-workspace-overview-to-string` and
  `render-workspace-attention-to-string` (`renderer-workspace.lisp`), drawing
  the organization → repository → worktree tree and the attention list.

The workspace views depend on `renderer-format.lisp` (generic ANSI primitives)
and nothing else in the pane renderer. They used to live inside
`renderer-compose.lisp`, which made the workspace UI appear to require the whole
VT100 stack; moving them out in 2026-08 made the real dependency visible, and the
ASDF load order now states it — `renderer-workspace` loads immediately after
`renderer-format`, ahead of the entire pane chain.

`renderer.lisp` is an intentionally empty load-order stub (see its own header
comment). `renderer-compose-protocols.lisp` holds one function, `clear-display`,
called by the client at raw-mode setup; it is not part of either render pass,
which is why no render entry point reaches it.

The cold-path read-model under `src/dataflow/` is described in
[Dogfooded sibling libraries](../guide/sibling-libraries.md).

It is **not part of the core `nerimux` system**. It has no call site anywhere in
`src/` outside its own directory, so loading it into the shipped binary bought
nothing at runtime while pulling `cl-dataflow-kit` into its dependency closure.
It lives in the optional system `nerimux/dataflow-model`, which its existing test
suite (`nerimux/dataflow`) depends on explicitly. The parallel `nerimux/reasoning`
system was retired when the key-table store it projected was deleted.

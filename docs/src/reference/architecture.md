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
  ▼                                              4. drain every buffered message
SIGWINCH ──► %maybe-send-resize                     from each ready client
  │  +msg-resize+ frame
  ▼                                                            │
   length-prefixed frame, Unix socket ───────────────────────► ▼
                                              %handle-multi-client-message
                                              (per-client CLIENT-CONN: its own
                                               rows/cols, view, modal, focus)
                                                            │
                       ┌────────────────────────────────────┼───────────────────────┐
                       ▼                                    ▼                        ▼
              repolist/status keymap,              focused pane's PTY       +msg-command+ payload
              C-q prefix, transients               (VIEW :pane, MODAL nil   → %handle-client-ui-command
              (per-CLIENT-CONN VIEW × MODAL          — pty-write via the      (workspace UI vocabulary:
               — %client-ui-keys-p derives            *write-pty* port)        wt-create, tree-*, picker-*,
               which of these three a key hits)                                view, modal …)
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
                                                  render-session-to-tui-string
                                                → +msg-frame+ frame back to that client
```

The client side of the diagram is `src/bootstrap/client.lisp`; everything on
the server side is keyed off the per-connection `CLIENT-CONN` struct in
`src/bootstrap/server-multi-dispatch.lisp`.

`CLIENT-CONN` holds two independent axes rather than one mode×view product:
`VIEW` (`:repolist` / `:status` / `:pane`) says which screen is up, and
`MODAL` (`NIL` / `:transient` / `:confirm` / `:help` / `:process-log` /
`:command` / `:picker` / `:filter` / `:scrollback`) says what, if anything,
has taken the keyboard away from that screen. With `MODAL` `NIL`, where a key
goes is *derived* from `VIEW` (`%client-ui-keys-p`,
`src/bootstrap/server-multi-dispatch.lisp`) rather than stored: there is no
state in which a pane is on screen and the workspace UI is nonetheless eating
keys, because there is no slot in which to record one. That is what replaced
the old `:normal`/`:input` mode pair — see [Getting
started](../getting-started.md#default-key-bindings) for the resulting
keymap.

The server renders **per client**, not once for the whole session: each
attached `CLIENT-CONN` can be at a different view (`repolist`/`status`/
`pane`), a different modal, and a different terminal size, so
`%render-client-frame` (`src/bootstrap/server-multi.lisp`) picks the matching
renderer and the client's own `rows`/`cols` on every broadcast. The shared
pane/PTY layout underneath is still sized once, from the smallest attached
client's geometry (`%effective-client-size`).

A key an attached client sends reaches a pane's PTY whenever `VIEW` is
`:pane` and `MODAL` is `NIL` — no mode to enter first. Every other key is
handled by the per-client workspace dispatcher (`%handle-multi-key-message`,
`src/bootstrap/server-multi-dispatch.lisp`); bindings are compiled into that
dispatcher and no configuration file is read.

## Layering

The layering rule is:

- `domain` defines the session/window/pane model and, in `domain/ports/`, the
  capabilities it needs from outside itself. The model stays independent of
  concrete I/O while its ports name the required capabilities.

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
  scattering raw `sb-ext:` calls through the model.

  Git is neither: it does not go through `domain` at all. `bootstrap` calls the
  `nerimux/vcs` infrastructure package directly (`workspace-organizations`,
  `refresh-workspace-organizations-async`, …), which is legal because bootstrap
  sits above every layer.
- `application` holds use cases over the domain model: `commands/` (copy
  mode, the command-line tokenizer, and pane PTY teardown) and `picker/` (the
  global picker item model).
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
`tests/unit/bootstrap/system-composition-tests.lisp`, which exist because each
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

The tests report the offending package or source reference so a violation can
be fixed at the layer boundary rather than hidden behind an allow-list.

Terminal code separates data (`types`) from logic (`actions`, `csi`, `sgr`, the
CPS parser) one level further down.

The bootstrap dispatch layer follows the same separation. The shared
`define-message-dispatch-fn` macro in `src/bootstrap/server.lisp` expands
declarative rules into the common conditional dispatch form. The
`define-multi-msg-dispatch` wrapper in `server.lisp` supplies the multi-client
handler shape used by `server-multi.lisp`; the client connection data lives in
the shared `server-multi-dispatch.lisp` module, while per-message helpers live in the
`server-multi-dispatch-prefix.lisp`, `server-multi-dispatch-picker.lisp`,
`server-multi-dispatch-command-input.lisp`, and `server-multi-dispatch-command.lisp`
files. The terminal parser is a CPS state machine, with its data
structs kept apart from the `actions`, `csi`, and `sgr` logic. Character writing is split by role:
`char-write-definitions.lisp` holds declarative charset and width facts,
`char-write-cells.lisp` owns cell placement, and `char-write.lisp` coordinates
charset remapping, wrapping, insertion, and cursor movement.
SGR follows the same dependency direction: `sgr-definitions.lisp` owns the
attribute rule table, `sgr-colors.lisp` decodes extended colours, `sgr.lisp`
coordinates application, and `sgr-report.lisp` encodes status reports.

## Source layout

`src/` is nested rather than flat so package boundaries remain discoverable.
Package definitions are correspondingly split across several
`src/bootstrap/package-*.lisp` fragments loaded by `src/bootstrap/package.lisp`.

```
nerimux/
├── flake.nix               # Nix build + checks (pure Lisp, no C compilation)
├── nerimux.asd             # ASDF systems: nerimux, /test, /pty-test
├── run-tests.lisp          # single Lisp-level test entry point
├── src/
│   ├── bootstrap/          # packages, entry point (`attach`/`server`), the
│   │                       #   client and server event loops, session registry
│   ├── domain/             # model, terminal logic, and capability ports
│   │   ├── terminal/       #   VT100/ANSI emulator (data structs ⁄ logic split)
│   │   ├── model/          #   session → window → pane tree, layouts
│   │   └── ports/          #   the PTY port variables, plus the posix wrappers
│   ├── application/        # use cases over the domain model
│   │   ├── commands/       #   scrollback (still named copy-mode internally)
│   │   │   └── copy-mode/  #     and the command-line tokenizer — what
│   │   │                   #     outlived the command table
│   │   └── picker/         #   global picker item model (build/filter across
│   │                       #   the workspace catalog)
│   ├── infrastructure/     # adapters: PTY, sockets, raw-mode stdin input, VCS
│   └── presentation/       # renderers
│       └── renderer/       #   pane compositor, workspace views, and cl-tui-kit
└── tests/
    ├── unit/               # feature-focused spec files
    ├── integration/        # PTY/socket/runtime integration specs
    └── e2e/                # binary-level smoke scenarios
```

The renderer has two independent first passes, and the split is deliberate:

- **The pane view** — `render-session-to-string` (`renderer-compose.lisp`),
  drawing the fixed one-row status line, laying out panes and emitting escape
  codes. This is the VT100 machinery: pane and border rendering, status-line
  composition, style/SGR emission, scrollback overlays (still `copy-mode` in
  source). Exercised on every frame that shows terminal content.
- **The workspace view** — `renderer-workspace-status-title.lisp` owns status
  labels and terminal titles shared by both views, while
  `renderer-workspace-command-line.lisp` owns workspace command completion.
  `renderer-workspace-tree.lisp` projects the repolist view's three fixed
  sections — Attention, Active, Repositories — flattening each worktree's
  optional inline expansion (panes, changed files, recent commits, and a
  changed file's own diff) into the same row list, including attention and
  refresh state.
  `render-workspace-overview-to-string` (`renderer-workspace.lisp`) draws those
  presentation values and that projection into the ANSI frame.

The `render-session-to-tui-string` and
`render-workspace-overview-to-tui-string` wrappers pass the selected ANSI frame
through `cl-tui-kit`'s headless surface. `renderer-tui-kit-frame-grid.lisp`
decodes ANSI cursor, erase, and text operations into a fixed grid;
`renderer-tui-kit-widgets.lisp` builds the picker and workspace-tree widgets;
`renderer-tui-kit.lisp` transfers the grid to a surface and owns the public
session/workspace entry points; and `renderer-tui-kit-confirm-view.lisp` owns
confirmation-view data and rendering.

The workspace view depends on `renderer-format.lisp` (generic ANSI primitives)
and `renderer-tui-kit.lisp`; the ASDF load order loads its status/title,
command-line, and tree-projection modules before `renderer-workspace`, all
ahead of the pane and composition modules.

The composition path is split across protocol, overlay, effect, and frame
modules. `renderer-compose-protocols.lisp` holds `clear-display`, called by the
client during raw-mode setup rather than by either render pass.

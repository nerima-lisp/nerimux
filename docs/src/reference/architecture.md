# Architecture

## Event flow

```
stdin ──► main thread ──► key tables / dispatch ──► pty-write(active pane fd)
                  ↑
               select(50ms timeout)
                  │
             render when dirty
                  │
          ┌───────┴────────┐
          │  active window │
          │  ┌───────────┐ │
          │  │   pane 0  │◄──── reader thread 0: blocking read(fd0)
          │  │  screen 0 │      → screen-process-bytes → *dirty* = T
          │  └───────────┘ │
          │  ┌───────────┐ │
          │  │   pane 1  │◄──── reader thread 1: blocking read(fd1)
          │  │  screen 1 │      → screen-process-bytes → *dirty* = T
          │  └───────────┘ │
          └────────────────┘
```

The renderer composites all pane screens into a single buffered write to
minimize flicker. Terminal resizes arrive via `SIGWINCH`, which flags a
one-shot relayout — geometry is never polled per frame, so a transient bad
`ioctl` read cannot trigger a resize storm.

In client/server mode the same `process-byte` pipeline runs server-side;
clients forward keystrokes and resizes as length-prefixed frames and paint
rendered frames back.

## Layering

The layering rule is:

- `domain` has no I/O.
- `application` orchestrates domain logic through port variables.
- `infrastructure` provides the real PTY/socket adapters.
- `presentation` turns model state into escape codes.

Terminal code separates data (`types`) from logic (`actions`, `csi`, `sgr`, the
CPS parser) one level further down.

## Source layout

`src/` is nested rather than flat — the one place cl-tmux deviates from the
organization's package standard, and a deliberate exception: at 266 source
files a flat directory stops being navigable. Package definitions are
correspondingly split across several `src/bootstrap/package-*.lisp` fragments
loaded by `src/bootstrap/package.lisp`.

```
cl-tmux/
├── flake.nix               # Nix build + checks (pure Lisp, no C compilation)
├── cl-tmux.asd             # ASDF systems: cl-tmux, /test, /weave, /dataflow
├── run-tests.lisp          # single Lisp-level test entry point
├── src/
│   ├── bootstrap/          # packages, entry point, runtime, server/client loops
│   ├── domain/             # pure model + logic (no I/O)
│   │   ├── terminal/       #   VT100/ANSI emulator (data structs ⁄ logic split)
│   │   ├── model/          #   session → window → pane tree, layouts
│   │   ├── format/         #   #{...} format-string engine
│   │   ├── options/        #   option registry + scopes
│   │   ├── hooks/          #   hook registry + firing
│   │   ├── buffer/         #   paste buffers
│   │   └── ports/          #   port variables (PTY, repository interfaces)
│   ├── application/        # use cases: command dispatch, config loading
│   │   ├── commands/       #   command implementations; tokenizer on cl-parser-kit
│   │   ├── config/         #   tmux.conf directives; shell calls on cl-boundary-kit
│   │   └── dispatch/       #   command table, handlers, control mode
│   ├── infrastructure/     # adapters: PTY, sockets, input, control mode
│   ├── presentation/       # renderer, events, prompt
│   ├── reasoning/          # cl-prolog-kit cold-path read-models (keys, commands)
│   └── dataflow/           # cl-dataflow-kit cold-path read-model (copy-mode lifecycle)
└── t/
    ├── unit/               # 250+ feature-focused spec files
    ├── integration/        # PTY/socket/runtime integration specs
    ├── weave/              # cl-weave suite for the reasoning read-model
    ├── dataflow/           # cl-weave suite for the copy-mode lifecycle read-model
    └── e2e/                # binary-level smoke test
```

The cold-path read-models under `src/reasoning/` and `src/dataflow/` are
described in [Dogfooded sibling libraries](../guide/sibling-libraries.md).

(in-package #:cl-user)

(defparameter *nerimux-test-components*
  '((:module "t"
     :serial t
     :components
      ((:file "package")
       (:file "suite")
       (:file "helpers-isolation")
      (:file "helpers-terminal-builders")
      (:file "helpers-render-output")
      (:file "helpers-events-cps")
      (:file "helpers-key-bindings")
      (:file "helpers-overlay-assertions")
      (:file "helpers-session-naming")
      (:file "helpers-pane-fixtures")
      (:file "helpers-pty-runtime")
      (:file "helpers-network-listener")
      (:file "helpers-net-protocol")
      (:file "helpers-options")
      (:file "helpers-prompt-history")
      (:file "helpers-process-fixtures")
      (:file "helpers-screen-assertions")
      (:file "helpers-loop-fixtures")
      (:file "helpers-mouse-fixtures")
      (:file "helpers-layout-fixtures")
      (:file "helpers-renderer-fixtures")
      (:file "helpers-session-fixtures")
      (:file "helpers-input-fixtures")
      (:file "helpers-pipe-fixtures")
      (:module "unit"
       :serial t
       :components
       ((:module "domain/terminal"
         :serial t
         :components
         ((:file "cell-tests") ; declares terminal-suite parent; cell data, width, combining
          (:file "cell-display-tests") ; DEC graphics, BCE, constants, hyperlink
          (:file "screen-tests") ; construction/p/cell-access/cursor/resize/dirty/sgr-pen/bell - part I
          (:file "screen-tests-b") ; copy-mode slots, alt-screen, mouse-sgr, response-queue, origin-mode, tab-stops, lock, cells/parser - part II
          (:file "screen-tests-c") ; screen-clear-dirty, reset-sgr-pen, bell-pending, screen-consume-bell, slots, copy-mode extra slots - part III
          (:file "screen-tests-d") ; title-stack, cwd, pending-wrap, focus-events, g0/g1/active-g, boolean-slot macro - part IV
          (:file "screen-queue-palette-tests") ; passthrough/clipboard queues and palette override storage
          (:file "screen-wrap-copy-tests") ; wrapped rows, ANSI boolean modes, copy-search-dir, rect-select
          (:file "cursor-tests") ; scroll-region-clamp, set-cursor, direct-action, tab-stops, ri, nel, wide-char, advance - part I
          (:file "cursor-tests-b") ; %place-wide-char, table-driven, combining-char-p, write-char combining, DEC graphics - part II
          (:file "cursor-tests-c") ; cursor-ri, cursor-nel, write-char-at-cursor wide, %advance-cursor no-wrap, movement behavioral - part III
          (:file "cursor-tests-d") ; cursor-lf direct, cursor-nl newline-mode, %materialize-tab-stops, BCE background, boundary table - part IV
          (:file "cursor-tests-e") ; custom multi-stop %next-tab-stop/%prev-tab-stop via HTS/TBC, table-driven regression - part V
          (:file "char-write-tests") ; combining-char-p = char-width; kana marks, ZWJ, controls
          (:file "scroll-tests") ; scroll-ops - part I
          (:file "scroll-erase-tests") ; ED/EL parser-path and direct erase coverage
          (:file "scroll-region-tests") ; DECSTBM, RI, IL/DL parser-path scroll-region coverage
          (:file "scroll-line-edit-tests") ; DCH/ICH parser-path line-edit coverage
          (:file "scroll-tests-b") ; direct-row-primitives, direct-action-erase, constrained-scroll, history-limit - part II
          (:file "scroll-tests-c") ; direct-line-edit (il/dl), scroll-screen-to-history, DEC-rect (DECERA/DECFRA/DECCRA) - part III
          (:file "scroll-tests-d") ; clear-scrollback, BCE background via %erase-cell, *scroll-on-clear-function* edge cases - part IV
          (:file "modes-tests") ; RIS/alt-screen/DECSC/mouse/bracketed-paste/focus - part I
          (:file "modes-tests-b") ; set-cursor-shape/bell-pending/set-charset/set-screen-title/reset-modes/alt-screen-direct - part II
          (:file "modes-tests-c") ; screen-invoked-charset/G0-G1, set-screen-cwd, erase-display-mode-3, IRM, LNM, DECSCNM, DECSTR - part III
          (:file "modes-tests-d") ; mouse DEC private modes, bracketed paste, focus events, app-cursor, auto-wrap, reset-sgr-pen, display-cell - part IV
          (:file "modes-tests-e") ; decstr-action/decaln-action direct calls, set-ansi-mode/reset-ansi-mode direct calls - part V
          (:file "sgr-tests") ; sgr suite: fg/bg tables, truecolor, colon SGR, pen-to-sgr-params - part I
          (:file "sgr-tests-b") ; direct-action-sgr, sgr-extended, extra codes, define-sgr-rules, consume-256-color - part II
          (:file "csi-tests") ; cursor-movement/DECSCUSR/CBT/SU-SD - part I
          (:file "csi-tests-d") ; REP/da-response/DECRQM/XTWINOPS/CPR/DA-table/REP-count-zero - part IV
          (:file "csi-tests-b") ; ECH/DSR/ich-dch/decstbm/execute-csi-direct/%csi-decstbm-params - part II
          (:file "csi-tests-c") ; csi-unknown-sequences/DECOM/cup-row/enqueue/XTPUSHTITLE/DEC-rect - part III
          (:file "parser-utf8-tests") ; utf8
          (:file "parser-osc-tests") ; special / OSC
          (:file "parser-escape-tests") ; special / ESC / CSI
          (:file "parser-tests-b") ; combining-chars/ACS/dcs-parsing/xtgettcap/decrqss - part II
          (:file "parser-control-state-tests") ; ground-state/escape-state/direct-dcs/G2-G3 shifts
          (:file "parser-osc-continuations-tests") ; direct OSC continuation bridge tests
          (:file "parser-osc-dispatch-tests") ; OSC payload edge cases
          (:file "parser-osc52-tests") ; OSC 52 clipboard coverage
          (:file "parser-osc7-tests") ; OSC 7 cwd parsing, percent decode, macro coverage
          (:file "parser-dcs-tests") ; direct DCS bridge and tmux passthrough
          (:file "parser-parser-utils-tests") ; helpers, parser-suite, base64, parse-osc-command, csi-colon
          (:file "parser-basic-text-tests") ; printable characters, CR/LF, wrap, BS, TAB - part IIIa
          (:file "parser-inline-predicate-tests") ; inline predicate helpers - part IIIb
          (:file "parser-state-cps-tests") ; direct CPS parser state functions + define-state - part IIIc
          (:file "emulator-tests")
          (:file "parser-fuzz-tests"))) ; it-fuzz coverage of screen-process-bytes
        (:module "domain/model"
         :serial t
         :components
         ((:file "layout-tests-geometry") ; layout-tree geometry: leaves/split/resize/remove/min-extent - part I
          (:file "layout-tests-macros") ; layout-tree helpers and macros - part II
          (:file "layout-tests-persistence") ; layout-tree persistence and string/flat-tree round-trips - part III
          (:file "layout-tests-b") ; named-layout helpers, apply-named-layout - part IV
          (:file "layout-tests-c") ; layout persistence internals: split-bounding-box, node-to-string, read-digits, round-trips - part V
          (:file "layout-tests-d") ; main-pane-extent table, layout-split defaults, checksum constants, zoomed pane-neighbor guard - part VI
          (:file "layout-geometry-tests") ; orientation helpers, layout-assign, resize-find-split, pane-at-position, split-child - part I
          (:file "layout-geometry-tests-b") ; %ranges-overlap-p, pane-center, closest-to-center, define-axis-rules, nested min-extent - part II
          (:file "pane-tests-geometry") ; pane feed/reposition, next-id, split-window
          (:file "pane-tests-ops") ; swap/capture/last/display/respawn
          (:file "pane-tests-accessors") ; pane defaults, accessors, feed dirty/empty
          (:file "pane-tests-predicates") ; hit-testing, live, pipe, border-status
          (:file "window-tests-relayout")
          (:file "window-tests-pane-ops")
          (:file "window-tests-split-math")
          (:file "window-tests-tree-ops")
          (:file "window-neighbor-tests") ; pane-neighbor directional lookup
          (:file "window-zoom-tests") ; even-layout, zoom toggle, lock slot
          (:file "window-tests-b") ; apply-named-layout (5 layouts), last-window/move/swap/rotate - part II
          (:file "window-tests-c") ; find-window-by-name, list-windows-format, auto-rename-from-osc - part III
          (:file "session-state-core")
          (:file "session-state-structural")
          (:file "session-lifecycle-tests")
          (:file "session-window-tests") ; start-directory, all-panes ordering, window flags
          (:file "session-environment-tests") ; environment overlay, process helpers, child env merge
          (:file "organization-tests")
          (:file "repository-tests")
          (:file "worktree-tests")
          (:file "attention-tests")))
        (:module "domain/text"
         :serial t
         :components
         ((:file "text-parse-tests"))) ; parse-integer-or-nil / non-empty-string; moved out of target-suite with the functions
        (:module "domain/ports"
         :serial t
         :components
         ((:file "posix-port-tests")))
        (:module "infrastructure/vcs"
         :serial t
         :components
         ((:file "vcs-tests")))
        (:module "domain/persistence"
         :serial t
         :components
         ((:file "runtime-state-tests")))
        (:module "application/picker"
         :serial t
         :components
         ((:file "global-picker-tests")))
        (:module "domain/format"
         :serial t
         :components
         ((:file "format-tests") ; format expansion - part I (shorthands, brace/conditional, context, window_flags, helpers)
          (:file "format-tests-d") ; format expansion - part IV (shorthand-table, %expand-brace, %truthy-p, pane/client vars)
          (:file "format-structural-tests") ; structural pane/session/window/terminal format variables
          (:file "format-modifier-tests") ; truncation/logical/quote/char/path modifiers
          (:file "format-tests-b") ; format expansion - part II (path/substitute/nested/strftime/context/glob/regex)
          (:file "format-tests-c") ; format expansion - part III (arithmetic/vars/geometry/pane_at_edges/pane-synchronized)
          (:file "format-tests-e") ; format expansion - part V (content-search, glob-match-p, pane-visible-lines, apply-pad-modifier, window-raw-flags)
          (:file "format-tests-f"))) ; format expansion - part VI (new context keys, modifier chaining, glob/regex match, format variables)
        (:module "domain/model-2"
         :pathname "domain/model"
         :serial t
         :components
         ((:file "target-tests") ; parse-session/window/pane/target, find-by-target - part I
          (:file "target-tests-b"))) ; %sigil-id, %name-prefix-p, edge cases, table-driven parse-target, multi-digit ids - part II
        (:module "domain/buffer"
         :serial t
         :components
         ((:file "buffer-tests-ring")
          (:file "buffer-tests-clipboard")
          (:file "buffer-tests-named")))
        (:module "domain/options"
         :serial t
         :components
         ((:file "options-tests") ; option registry, coercions, boolean defaults, make-option-spec - part I
          (:file "options-display-tests") ; scope/display presence, array names, value display quoting
          (:file "options-tests-b") ; define-option-accessor, type-coercions, scoped overrides, show-options - part II
          (:file "options-tests-c"))) ; type-coercion dispatch, option-table macro, spec accessors, server options, show-option sorting - part III
        (:module "domain/hooks"
         :serial t
         :components
         ((:file "hooks-tests"))) ; hook-event-constants, hook-registry, add/run/remove/clear/list-hooks
        (:module "application/config"
         :serial t
         :components
         ((:file "config-key-table-runtime-tests")
          (:file "config-directives-tests") ; directive parsing - part I (suite, bindable commands, basic apply/set directives)
          (:file "config-load-tests") ; directive parsing - load strings/streams/files and config paths
          (:file "config-bind-directive-tests") ; directive parsing - bind/unbind, notes, brace blocks, sequences
          (:file "config-directives-tests-c") ; directive parsing - part III (load-config-file, command-keyword, parse-bind-args, key-table edge cases)
          (:file "config-directives-tests-b") ; directive parsing - part II (%parse-bind-args, tokenizer, set aliases, server flag, terminal option routing)
          (:file "config-source-run-tests") ; directive parsing - source-file, run-shell, path expansion
          (:file "config-if-shell-tests") ; directive parsing - if-shell flags, format truthiness, brace blocks
          (:file "config-source-file-tests") ; directive parsing - source-file flags, glob expansion, missing diagnostics
          (:file "config-preprocessor-environment-tests") ; directive parsing - preprocessor, environment, key-table side effects
          (:file "config-directives-tests-d") ; directive parsing - part IV (set-g-status-off, bind-key-n, load-config, %elif, line-continuation, comments, styles)
          (:file "config-directives-tests-e"))) ; directive parsing - part V (macro registry, env-set-p, key-table edge cases, remaining bind/set directives)
        (:module "presentation/renderer"
         :serial t
         :components
         ((:file "renderer-format-tests") ; SGR codes, style tokens, border-color, cursor-shape, palette bounds - part I
          (:file "renderer-format-tests-b") ; all-attrs table, attrs2, ul-color, style-token/emit remaining, parse-style, border-charset - part II
          (:file "renderer-pane-tests") ; render-pane content/borders/window-style - part I
          (:file "renderer-pane-tests-b") ; %clock-digit-rows, %render-v-separator, border/pane edge cases - part II
          (:file "renderer-pane-tests-c") ; %apply-border-style branches, draw-clock, render-pane-clock-mode, draw-pane-number, in-sel-branch - part III
          (:file "renderer-tests") ; renderer - part I (status-bar, render-session, clear-display, status-indicators, window-list)
          (:file "renderer-window-list-tests") ; renderer status window-list styles and format expansion
          (:file "renderer-tests-d") ; renderer - part IV (per-window options, alert-tab-styles, status-bar-line)
          (:file "renderer-overlay-cursor-tests") ; renderer overlay, cursor visibility, message placement
          (:file "renderer-tests-b") ; renderer - part II (status-bar, status-position, BEL rendering, status-left-expanded)
          (:file "renderer-tests-f") ; renderer - part VI (parse-style-string, style-to-sgr, status-length, window-status-format, render-popup/menu)
          (:file "renderer-tests-c") ; renderer - part III (mouse/focus/keys, lock-screen, justify, cursor-shape, zoom-suppression)
          (:file "renderer-tests-e") ; renderer - part V (%clamp-status-segment, cursor-shape in output, status-bar-line gap, inline-style, bell relay)
          (:file "renderer-tests-g") ; renderer - part VII (%split-align-attr, %status-align-buckets, %status-bar-default-segments, %content-search-match-p flag matrix)
         (:file "renderer-statusbar-layout-tests") ; direct unit tests for the previously-untested statusbar-layout helpers
         (:file "renderer-pane-selection-tests") ; direct unit tests for %compute-selection-bounds
         (:file "renderer-compose-effects-tests") ; direct unit tests for %render-passthrough/%render-clipboard drain gating
         (:file "renderer-overlay-layer-tests") ; direct unit tests for %render-overlay-layer's popup>menu>overlay>cursor priority dispatch
         (:file "renderer-pane-search-tests") ; direct unit tests for %render-copy-search-matches's current-vs-plain match style branch
         (:file "renderer-tui-kit-tests"))) ; headless cl-tui-kit surface/backend adapter
 ; wait-for command channel state and argument validation
        (:module "application/commands"
         :serial t
         :components
         ((:file "commands-tests") ; resize-pane, scroll, select/rename - part I
          (:file "commands-pane-lifecycle-tests") ; close-pane-pty: fd/pid order, error swallowing
          (:file "commands-tests-e") ; copy-mode WORD-motion and cursor movement - part II
          (:file "commands-tests-f") ; rename-window, kill-window, linear selection-text - part III
          (:file "commands-tests-m") ; shift-line-wrapped, line-wrapped flag on erase - part XIII
          (:file "commands-tests-n") ; copy-mode-begin-selection multi-row, yank, other-end - part XIV
          (:file "commands-tests-k") ; begin-line-selection, copy-end-of-line (D), copy-line (Y), search-forward/backward, wrap-search - part XI
          (:file "commands-tests-g") ; tokenize-command-string, message-log append/cap/order - part V
          (:file "commands-tests-h") ; copy-mode exit and half-page scroll, clear-history, rotate - part VI
          (:file "commands-window-navigation-tests") ; find-window and next/previous/last-window command behavior
          (:file "commands-tests-c") ; pipe-pane, virtual-row, timeout, scroll helpers, word/paragraph nav - part VII
          (:file "commands-tests-o") ; selection-bounds scrollback, word/paragraph nav, scroll-middle - part XV
          (:file "commands-tests-j") ; resize up, copy-mode search/scroll/word-bounds, row extraction - part X
          (:file "commands-tests-l") ; copy-mode exit resets rect-select, yank-rectangle fixed columns - part XII
          (:file "commands-tests-i") ; rectangle selection-text, run-copy-command, copy-mode set-cursor - part IX
          (:file "commands-copy-navigation-tests"))) ; copy-mode search next/prev/forward/backward guards
        (:module "presentation/prompt"
         :serial t
         :components
         ((:file "overlay-tests")
          (:file "overlay-popup-menu-tests")
          (:file "overlay-transient-tests")
          (:file "prompt-tests")
          (:file "prompt-editing-tests")
          (:file "prompt-tests-wiring")))
        (:module "application/config-2"
         :pathname "application/config"
         :serial t
         :components
         ((:file "config-tests-defaults")))
        (:module "infrastructure/net"
         :serial t
         :components
         ((:file "protocol-tests") ; octets/frame-header/round-trips/msg-command - part I
          (:file "protocol-tests-b") ; field/text codecs and basic command payload round-trips - part II
          (:file "protocol-binary-layout-tests") ; integer encoders, frame layout, attach payload boundaries
          (:file "protocol-command-payload-tests") ; target detection and encode-command-payload ordering
          (:file "protocol-command-malformed-utf8-tests") ; strict command decode + drop guard
          (:file "transport-tests") ; round-trips, with-incoming-frame, %read-exact - part I
          (:file "transport-tests-b"))) ; validation, security boundaries, CPS-phase direct coverage - part II
        (:module "bootstrap"
         :serial t
         :components
         ((:file "server-registry-tests")
          (:file "server-window-link-tests")
          (:file "server-command-tests")
          (:file "server-session-listing-tests") ; list-sessions, rename-session, switch-client, session groups
          (:file "server-session-message-tests") ; session groups, dispatch, attach/resize edge cases
          (:file "server-socket-path-tests") ; socket paths and stale sockets
          (:file "server-client-cps-tests") ; client key CPS, runtime registry, resize edge cases
          (:file "runtime-lifecycle-tests")
          (:file "system-composition-tests"))) ; core excludes the optional reasoning/dataflow kits
        (:module "infrastructure/pty"
         :serial t
         :components
         ((:file "pty-ffi-tests")
          (:file "pty-rawmode-tests")
          (:file "pty-tests"))) ; PTY argument-assembly unit tests (spawn helpers)
        (:module "infrastructure/input"
         :serial t
         :components
         ((:file "input-tests")))
        (:module "bootstrap-2"
         :pathname "bootstrap"
         :serial t
         :components
         ((:file "runtime-tests") ; globals, pane-reader-loop, EOF/remain-on-exit, alert actions
          (:file "runtime-reader-cps-tests") ; reader CPS state machine contracts
          (:file "runtime-channel-helper-tests") ; cap-list and channel plist helpers
          (:file "runtime-prompt-history-io-tests")
          (:file "runtime-message-log-core-tests")
          (:file "runtime-tests-c") ; stop-reader-threads, add-message-log, add-prompt-history, wait-for-channel - part III
          (:file "runtime-tests-b") ; add-message-log table-driven, add-prompt-history, wait-for-channel - part II
          (:file "main-tests")
          (:file "main-entry-tests")))
        (:module "feature"
         :serial t
         :components
         ((:file "advanced-tests"))))) ; cross-layer acceptance suite (break/pipe/sync, layout, lock, session-groups)
      (:module "integration"
       :serial t
       :components
        ((:file "net-tests")
         (:file "server-multi-tests-support")
         (:file "server-multi-tests-size")
         (:file "server-multi-tests-message-dispatch")
         (:file "server-multi-tests-forwarding")
         (:file "server-multi-tests-loop")
        (:file "server-multi-command-client-tests")
        (:file "pty-tests")
         (:file "client-tests-support")
         (:file "client-tests-frame-dispatch")
         (:file "client-tests-startup-modes")
         (:file "client-tests-command-client")
         (:file "client-receive-tests")))))))

(in-package #:cl-user)

(defparameter *nerimux-test-components*
  '((:module "tests"
     :serial t
     :components
      ((:file "package")
       (:file "suite")
      (:file "helpers-render-output")
      (:file "helpers-key-bindings")
      (:file "helpers-session-naming")
      (:file "helpers-pane-fixtures")
      (:file "helpers-process-fixtures")
      (:file "helpers-loop-fixtures")
      (:file "helpers-layout-fixtures")
      (:file "helpers-renderer-fixtures")
      (:file "helpers-session-fixtures")
      (:file "helpers-input-fixtures")
      ;; Split out of the terminal helpers when domain/terminal became
      ;; nerimux-terminal: one reaches nerimux/commands, the other binds
      ;; nerimux:: server state, so neither can live in a DOMAIN unit.
      (:file "helpers-copy-mode-fixtures")
      (:file "helpers-command-state")
      (:module "unit"
       :serial t
       :components
       ((:module "domain/model"
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
          (:file "pane-tests-predicates") ; hit-testing, live, pipe
          (:file "window-definition-tests") ; declarative record expansion
          (:file "window-tests-relayout")
          (:file "window-tests-split-math")
          (:file "window-tests-tree-ops")
          (:file "window-neighbor-tests") ; pane-neighbor directional lookup
          (:file "window-zoom-tests") ; even-layout, zoom toggle, lock slot
          (:file "window-tests-b") ; apply-named-layout (5 layouts), last-window/move/swap/rotate - part II
          (:file "window-tests-c") ; find-window-by-name, list-windows-format, auto-rename-from-osc - part III
          (:file "session-state-core")
          (:file "session-state-structural")
          (:file "session-window-tests") ; start-directory, all-panes ordering, window flags
          (:file "session-environment-tests") ; environment overlay, process helpers, child env merge
          (:file "organization-tests")
          (:file "repository-tests")
          (:file "worktree-tests")
          (:file "attention-tests")
          (:file "advanced-tests"))) ; layout persistence round-trip and update-environment defaults; moved from tests/unit/feature/ (model-layer concern, not a cross-layer feature)
        (:module "infrastructure/vcs"
         :serial t
         :components
         ((:file "vcs-tests")
          (:file "vcs-fetch-dedup-tests") ; R7.1: one fetch in flight per target
          (:file "vcs-worktree-path-tests") ; R7.2: timestamp-sha path, -2/-3 on collision
          (:file "vcs-operations-tests")
          (:file "vcs-async-operations-tests")
          (:file "vcs-inspect-tests"))) ; Wave B: recent-commit fetch for the inline expansion
        (:module "application/picker"
         :serial t
         :components
         ((:file "global-picker-tests")))
        (:module "domain/model-2"
         :pathname "domain/model"
         :serial t
         :components
         ((:file "target-tests") ; parse-session/window/pane/target, find-by-target - part I
          (:file "target-tests-b"))) ; %sigil-id, %name-prefix-p, edge cases, table-driven parse-target, multi-digit ids - part II
        (:module "presentation/renderer"
         :serial t
         :components
         ((:file "renderer-format-tests") ; SGR codes, style tokens, border-color, cursor-shape, palette bounds - part I
          (:file "renderer-format-tests-b") ; all-attrs table, attrs2, ul-color, style-token/emit remaining, parse-style, border-charset - part II
          (:file "renderer-pane-tests") ; render-pane content/borders/window-style - part I
          (:file "renderer-pane-tests-b") ; %clock-digit-rows, %render-v-separator, border/pane edge cases - part II
          (:file "renderer-pane-tests-c") ; %apply-border-style branches, draw-clock, render-pane-clock-mode, draw-pane-number, in-sel-branch - part III
          (:file "renderer-tests") ; renderer - part I (status-bar, render-session, clear-display)
          (:file "renderer-tests-b") ; renderer - part II (status-bar, status-position, BEL rendering, status-left-expanded)
          (:file "renderer-tests-c") ; renderer - part III (mouse/focus/keys, lock-screen, cursor-shape, zoom-suppression)
          (:file "renderer-tests-e") ; renderer - part V (%clamp-status-segment, cursor-shape in output, status-bar-line gap, inline-style, bell relay)
          (:file "renderer-tests-g") ; renderer - part VII (%split-align-attr, %status-align-buckets, %status-bar-default-segments, %content-search-match-p flag matrix)
         (:file "renderer-statusbar-layout-tests") ; direct unit tests for the previously-untested statusbar-layout helpers
         (:file "renderer-pane-selection-tests") ; direct unit tests for %compute-selection-bounds
         (:file "renderer-compose-effects-tests") ; direct unit tests for %render-passthrough/%render-clipboard drain gating
         (:file "renderer-pane-search-tests") ; direct unit tests for %render-copy-search-matches's current-vs-plain match style branch
      (:file "renderer-workspace-status-tokens-tests") ; R6.1: tokens combine; CLEAN vs UNKNOWN
      (:file "renderer-workspace-clip-tests") ; R6.9: clipping measures cells, not characters
      (:file "renderer-workspace-tree-tests") ; Attention/Active/Repositories sections; Repositories collapsed by default
      (:file "renderer-workspace-command-completion-tests") ; R6.12
      (:file "renderer-statusbar-workspace-tests") ; R6.5/R6.7: three blocks, truncation order
      (:file "renderer-copy-mode-position-tests") ; R6.8
      (:file "renderer-tui-kit-min-size-tests") ; R6.10
         (:file "renderer-tui-kit-tests") ; headless cl-tui-kit surface/backend adapter
         (:file "renderer-tui-kit-help-tests") ; full-screen key reference, reached from the `?` transient
         (:file "renderer-transient-tests") ; magit transient panel + `$` process log (FR-010/FR-011)
         (:file "renderer-workspace-status-tests"))) ; magit-style per-worktree status view (FR-003)
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
        (:module "bootstrap"
         :serial t
         :components
         ((:file "server-registry-tests")
          (:file "server-window-link-tests")
          (:file "server-session-listing-tests")
          (:file "server-socket-path-tests") ; socket paths and stale sockets
          (:file "server-client-cps-tests") ; client key CPS, runtime registry, resize edge cases
          (:file "server-dispatch-helper-tests") ; selection, picker, and command helper algebra
          (:file "runtime-lifecycle-tests")
      (:file "server-kill-request-tests") ; R8.1/R8.3
      (:file "workspace-window-naming-tests") ; R5.8
      (:file "workspace-catalog-refresh-state-tests") ; FR-005: mark/settle, not re-mark
          (:file "system-composition-tests"))) ; layering guard; core declares no optional kit
        (:module "bootstrap-2"
         :pathname "bootstrap"
         :serial t
         :components
         ((:file "runtime-tests") ; globals, pane-reader-loop, EOF/remain-on-exit, alert actions
          (:file "runtime-reader-cps-tests") ; reader CPS state machine contracts
          (:file "runtime-channel-helper-tests") ; cap-list and channel plist helpers
          (:file "runtime-tests-c") ; stop-reader-threads, wait-for-channel - part III
          (:file "runtime-tests-b") ; wait-for-channel - part II
          (:file "main-tests")
          (:file "main-entry-tests")))))
      (:module "integration"
       :serial t
       :components
        ((:file "net-malformed-utf8-dispatch-tests") ; spans nerimux-net and the bootstrap event loop
         (:file "net-tests")
         (:file "server-multi-tests-support")
         (:file "server-multi-tests-size")
         (:file "server-multi-tests-message-dispatch")
         (:file "server-multi-tests-message-dispatch-worktree")
         (:file "server-multi-tests-message-dispatch-errors")
         (:file "server-multi-tests-message-dispatch-picker")
         (:file "server-multi-tests-message-dispatch-routing")
         (:file "server-multi-tests-forwarding")
         (:file "server-multi-tests-loop")
        (:file "server-multi-command-client-tests")
        (:file "pty-tests")
         (:file "client-tests-support")
         (:file "client-tests-frame-dispatch")
         (:file "client-tests-startup-modes")
         (:file "client-tests-command-client")
         (:file "workspace-input-prefix-tests") ; R4: driven from client bytes
         (:file "workspace-panes-acceptance-tests") ; R5 acceptance sequence
         (:file "confirm-view-quit-tests") ; R8.2
         (:file "attach-selector-resolution-tests") ; R7.6
         (:file "client-receive-tests")))))))

(defmacro define-system-with-nerimux-test-components (name &rest options)
  (append (list (intern "DEFSYSTEM" "ASDF") name)
          options
          (list :components *nerimux-test-components*)))

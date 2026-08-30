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
      (:file "helpers-process-fixtures")
      (:file "helpers-loop-fixtures")
      (:file "helpers-renderer-fixtures")
      (:file "helpers-session-fixtures")
      (:file "helpers-input-fixtures")
      ;; Split out of helpers-layout-fixtures.lisp when domain/model became
      ;; nerimux-model: this one wraps its body in WITH-LOOP-STATE, which binds
      ;; nerimux:: server state, so a DOMAIN unit cannot carry it.
      (:file "helpers-layout-loop-fixtures")
      ;; Split out of the terminal helpers when domain/terminal became
      ;; nerimux-terminal: one reaches nerimux/commands, the other binds
      ;; nerimux:: server state, so neither can live in a DOMAIN unit.
      (:file "helpers-copy-mode-fixtures")
      (:file "helpers-command-state")
      (:module "unit"
       :serial t
       :components
        ((:module "presentation/renderer"
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
          (:file "system-composition-tests") ; layering guard; core declares no optional kit
          ;; Moved from tests/unit/domain/model/ with the extraction of
          ;; nerimux-model. target.lisp itself moved to src/bootstrap/ earlier;
          ;; these reference nerimux:: internals and were never model tests, only
          ;; tests that had not followed their subject.
          (:file "target-tests") ; parse-session/window/pane/target, find-by-target - part I
          (:file "target-tests-b"))) ; %sigil-id, %name-prefix-p, edge cases, table-driven parse-target, multi-digit ids - part II
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
        ((:file "pane-response-queue-pty-tests") ; spans nerimux-model and the real nerimux-pty adapter
         (:file "net-malformed-utf8-dispatch-tests") ; spans nerimux-net and the bootstrap event loop
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

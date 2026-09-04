(in-package #:cl-user)

(defparameter *nerimux-test-components*
  '((:module "tests"
     :serial t
     :components
      ((:file "package")
       (:file "suite")
      (:file "helpers-key-bindings")
      (:file "helpers-session-naming")
      (:file "helpers-process-fixtures")
      (:file "helpers-loop-fixtures")
      (:file "helpers-session-fixtures")
      (:file "helpers-input-fixtures")
      (:file "helpers-layout-loop-fixtures")
      (:file "helpers-command-state")
      (:module "unit"
       :serial t
       :components
        ((:module "bootstrap"
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
        ((:file "pane-response-queue-pty-tests") ; spans nerimux-model and the concrete nerimux-pty implementation
         (:file "net-malformed-utf8-dispatch-tests") ; spans nerimux-net and the bootstrap event loop
         (:file "commands-clear-history-tests") ; binds nerimux:: server state around a commands case
         (:file "renderer-selection-copy-mode-tests") ; renderer bounds over a commands-built copy-mode screen
         (:file "renderer-copy-search-highlight-tests") ; renderer highlight over a commands-built copy-mode screen
         (:file "renderer-copy-mode-frame-tests") ; same, through a full rendered frame
         (:file "renderer-help-transient-tests") ; renderer help sections against the bootstrap transient table
         (:file "picker-selection-token-tests") ; picker tokens are bootstrap internals, not picker ones
         (:file "workspace-file-diff-cache-tests") ; the cache is bootstrap state, keyed by worktree and file
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

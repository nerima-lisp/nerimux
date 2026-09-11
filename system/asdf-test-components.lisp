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
         ((:file "helpers-stubbed-fdefinitions")
          (:file "server-registry-tests")
          (:file "server-window-link-tests")
          (:file "server-session-listing-tests")
          (:file "server-socket-path-tests")
          (:file "server-client-cps-tests")
          (:file "server-dispatch-helper-fixtures")
          (:file "server-dispatch-helper-error-tests")
          (:file "server-dispatch-helper-tests")
          (:file "server-dispatch-helper-selection-tests")
          (:file "server-dispatch-helper-refresh-tests")
          (:file "server-dispatch-helper-catalog-refresh-tests")
          (:file "server-dispatch-helper-status-tests")
          (:file "server-dispatch-helper-search-tests")
          (:file "server-dispatch-helper-navigation-tests")
          (:file "runtime-lifecycle-tests")
      (:file "server-kill-request-tests")
      (:file "workspace-window-naming-tests")
      (:file "workspace-catalog-refresh-state-tests")
          (:file "system-composition-tests")
          (:file "target-tests")
          (:file "target-tests-b")))
        (:module "bootstrap-2"
         :pathname "bootstrap"
         :serial t
         :components
         ((:file "runtime-tests")
          (:file "runtime-reader-cps-tests")
          (:file "runtime-channel-helper-tests")
          (:file "runtime-tests-c")
          (:file "runtime-tests-b")
          (:file "main-tests")
          (:file "main-entry-tests")))))
      (:module "integration"
       :serial t
       :components
        ((:file "pane-response-queue-pty-tests")
         (:file "net-malformed-utf8-dispatch-tests")
         (:file "commands-clear-history-tests")
         (:file "renderer-selection-copy-mode-tests")
         (:file "renderer-copy-search-highlight-tests")
         (:file "renderer-copy-mode-frame-tests")
         (:file "renderer-help-transient-tests")
         (:file "picker-selection-token-tests")
         (:file "workspace-file-diff-cache-tests")
         (:file "net-tests")
         (:file "server-multi-tests-support")
         (:file "server-multi-tests-size")
         (:file "server-multi-tests-message-dispatch-selection")
         (:file "server-multi-tests-message-dispatch-commands")
         (:file "server-multi-tests-message-dispatch-rendering")
         (:file "server-multi-tests-message-dispatch-forwarding")
         (:file "server-multi-tests-message-dispatch-status")
         (:file "server-multi-tests-message-dispatch-worktree-commands")
         (:file "server-multi-tests-message-dispatch")
         (:file "server-multi-tests-transient")
         (:file "server-multi-tests-client-frame-dispatch")
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
         (:file "workspace-input-prefix-tests")
         (:file "workspace-panes-acceptance-tests")
         (:file "confirm-view-quit-tests")
         (:file "attach-selector-resolution-tests")
         (:file "client-receive-tests")))))))

(defmacro define-system-with-nerimux-test-components (name &rest options)
  (append (list (intern "DEFSYSTEM" "ASDF") name)
          options
          (list :components *nerimux-test-components*)))

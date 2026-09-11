(in-package #:asdf-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (load
   (merge-pathnames "system/asdf-test-components.lisp"
                    (uiop:pathname-directory-pathname
                     (or *load-truename*
                         *load-pathname*
                         (error
                          "Cannot locate nerimux.asd while loading test components."))))))

;;; Register package systems before the root system names them in :depends-on.
;;; ASDF's central registry is non-recursive, and the test runner clears the
;;; source registry before loading tests.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter cl-user::*nerimux-units*
    '("nerimux-text" "nerimux-version" "nerimux-ports" "nerimux-pty"
      "nerimux-net" "nerimux-input" "nerimux-terminal" "nerimux-model"
      "nerimux-picker" "nerimux-vcs" "nerimux-commands" "nerimux-renderer"))
  (let ((here (uiop:pathname-directory-pathname
               (or *load-truename*
                   *load-pathname*
                   (error "Cannot locate nerimux.asd while registering packages/.")))))
    (dolist (name cl-user::*nerimux-units*)
      (unless (asdf:find-system name nil)
        (let ((asd
                (merge-pathnames
                 (make-pathname
                  :directory (list :relative "packages"
                                   (subseq name (length "nerimux-")))
                  :name name
                  :type "asd")
                 here)))
          (unless (probe-file asd)
            (error "Unit ~A is named in nerimux.asd but ~A does not exist." name asd))
          (load asd))))))

(defsystem "nerimux"
  :description "A git-worktree workspace multiplexer in Common Lisp"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  ;; flake.nix reads this value and release.yml checks tags against it.
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on (:cl-date-kit      ; exact elapsed-time values for deadline APIs
               :cl-concurrent-kit
               :cl-regex-kit
               :cl-cli
               :cl-parser-kit
               :cl-tty-kit
               :cl-process-kit
               :cl-codec-kit
               :cl-host-kit
               :cl-tui-kit/ansi
               :cl-tui-kit/layout
               :cl-tui-kit/widgets
               :cl-vcs-kit
               "nerimux-text"
               "nerimux-version"
               "nerimux-ports"
               "nerimux-pty"
               "nerimux-net"
               "nerimux-input"
               "nerimux-terminal"
               "nerimux-model"
               "nerimux-picker"
               "nerimux-vcs"
               "nerimux-commands"
               "nerimux-renderer")
  :components
  ((:module "src"
    :serial t
     :components
     ((:file "package")
       (:file "target")
       (:file "server-dispatch-macros")
       (:file "runtime-data")
       (:file "runtime")
       (:file "runtime-reader-data")
       (:file "runtime-reader")
       (:file "session-registry")
       (:file "server-data")
       (:file "server")
       (:file "workspace-window-data")
       (:file "workspace-window")
       (:file "server-multi-data")
       (:file "server-multi-dispatch")
       (:file "server-multi-dispatch-prefix-data")
       (:file "server-multi-dispatch-fetch")
       (:file "server-multi-dispatch-confirm")
       (:file "server-multi-dispatch-prefix")
       (:file "server-multi-workspace-selection")
       (:file "server-multi-dispatch-picker-data")
       (:file "server-multi-dispatch-picker")
       (:file "server-multi-dispatch-picker-input")
       (:file "server-multi-dispatch-picker-open")
       (:file "server-multi-dispatch-command-workspace-relative")
       (:file "server-multi-dispatch-command-workspace-data")
       (:file "server-multi-dispatch-command-workspace")
       (:file "server-multi-dispatch-command-workspace-context")
       (:file "server-multi-dispatch-command-worktree-create")
       (:file "server-multi-dispatch-command-worktree")
       (:file "server-multi-command-input-primitives")
       (:file "server-multi-transient-data")
       (:file "server-multi-dispatch-transient-render")
       (:file "server-multi-dispatch-transient")
       (:file "server-multi-dispatch-command-input-data")
       (:file "server-multi-dispatch-command-input-mode-data")
       (:file "server-multi-dispatch-command-input-tree-filter")
       (:file "server-multi-dispatch-command-input-mode-commands")
       (:file "server-multi-dispatch-command-input-mode-refresh")
       (:file "server-multi-dispatch-command-status")
       (:file "server-multi-dispatch-command-input-mode")
       (:file "server-multi-dispatch-command-input")
       (:file "server-multi-dispatch-command-input-process-log")
       (:file "server-multi-dispatch-command-input-keymap")
       (:file "server-multi-dispatch-tree-filter-data")
       (:file "server-multi-dispatch-tree-filter")
       (:file "server-multi-dispatch-command")
       (:file "server-multi-state")
       (:file "server-multi")
       (:file "server-multi-render")
       (:file "server-multi-loop")
       (:file "runtime-lifecycle")
       (:file "client")
       (:file "main-startup-flags")
       (:file "main-startup-socket-data")
       (:file "main-startup-socket-macros")
       (:file "main-startup-socket")
       (:file "main-startup-data")
       (:file "main-startup-commands")
       (:file "main-startup"))))
  :build-operation "program-op"
  :build-pathname "nerimux"
  :entry-point "nerimux:main"
  :in-order-to ((test-op (test-op "nerimux/test"))))

(cl-user::define-system-with-nerimux-test-components "nerimux/test"
  :description "Test suite for nerimux, authored natively in cl-weave"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0")
               "nerimux-text/test"
               "nerimux-ports/test"
               "nerimux-pty/test"
               "nerimux-net/test"
               "nerimux-input/test"
               "nerimux-terminal/test"
               "nerimux-model/test"
               "nerimux-picker/test"
               "nerimux-vcs/test"
               "nerimux-commands/test"
               "nerimux-renderer/test")
  :perform (test-op (op c)
             (declare (ignore op c))
             (funcall (find-symbol "RUN-TESTS" (find-package "NERIMUX/TEST")))))

;; The sandbox has no /dev/ptmx, so real-PTY cases run in a separate suite.
;; Run with: nix run .#test-pty
(defsystem "nerimux/pty-test"
  :description "Real-PTY suite for nerimux: every case that forks a shell under a pseudo-terminal."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0"))
  :pathname "tests/pty"
  :serial t
  :components ((:file "package") (:file "helpers")
                                 (:file "pty-unit-tests")
                                 (:file "pty-integration-tests")
                                 (:file "pane-tests-geometry-pty")
                                 (:file "pane-tests-ops-pty")
                                 (:file "window-tests-c-pty")
                                 (:file "window-tests-pane-ops")
                                 (:file "window-tests-split-math-pty")
                                 (:file "session-lifecycle-tests")
                                 (:file "server-command-tests")
                                 (:file "server-client-cps-pty-tests")
                                 (:file "server-multi-command-client-pty-tests")
                                 (:file "entry"))
  :perform (test-op (op c)
                    (declare (ignore op c))
                    (funcall
                     (find-symbol "RUN-PTY-TESTS"
                                  (find-package "NERIMUX/PTY-TEST")))))

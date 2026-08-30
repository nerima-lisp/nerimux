;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-model"
  :description "DOMAIN workspace model for nerimux: organizations, repositories, worktrees, panes, layouts, windows, sessions"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; nerimux/pane :uses both: nerimux/ports for the PTY spawn hooks, and
  ;; nerimux/terminal for the screen a pane owns.
  :depends-on ("nerimux-ports" "nerimux-terminal"
               :cl-concurrent-kit :cl-host-kit :cl-tty-kit)
  :pathname "src"
  ;; Five packages share this system because they are mutually recursive:
  ;; workspace-model<->pane, pane<->session and layout<->window each close a
  ;; cycle. Splitting them further needs those cut first, not a new .asd.
  :serial t
  :components (
               (:file "package")
               (:file "organization")
               (:file "repository")
               (:file "worktree")
               (:file "pane-core")
               (:file "attention")
               (:file "pane-geometry")
               (:file "layout")
               (:file "layout-visitor")
               (:file "layout-persistence")
               (:file "layout-geometry")
               (:file "window-definitions")
               (:file "window-core")
               (:file "window-tree")
               (:file "window-operations")
               (:file "window-neighbor")
               (:file "session")
               (:file "session-environment-process")
               (:file "session-environment-overlay")
               (:file "session-environment-child")
               (:file "pane-spawn")               )
  :in-order-to ((test-op (test-op "nerimux-model/test"))))

(defsystem "nerimux-model/test"
  :description "Test suite for nerimux-model"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; Both edges mirror nerimux-model's own :depends-on.
  :depends-on ("nerimux-model" "nerimux-ports/test" "nerimux-terminal/test"
               (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-pane-fixtures")
               (:file "helpers-layout-fixtures")
               (:file "helpers-session-builders")
               (:file "helpers-session-environment")
               (:file "layout-tests-geometry")
               (:file "layout-tests-macros")
               (:file "layout-tests-persistence")
               (:file "layout-tests-b")
               (:file "layout-tests-c")
               (:file "layout-tests-d")
               (:file "layout-geometry-tests")
               (:file "layout-geometry-tests-b")
               (:file "pane-tests-geometry")
               (:file "pane-tests-ops")
               (:file "pane-tests-accessors")
               (:file "pane-tests-predicates")
               (:file "window-definition-tests")
               (:file "window-tests-relayout")
               (:file "window-tests-split-math")
               (:file "window-tests-tree-ops")
               (:file "window-neighbor-tests")
               (:file "window-zoom-tests")
               (:file "window-tests-b")
               (:file "window-tests-c")
               (:file "session-state-core")
               (:file "session-state-structural")
               (:file "session-window-tests")
               (:file "session-environment-tests")
               (:file "organization-tests")
               (:file "repository-tests")
               (:file "worktree-tests")
               (:file "attention-tests")
               (:file "advanced-tests")               )
  ;; See packages/text/nerimux-text.asd for why this form is repeated per unit
  ;; rather than shared, and why *PRINT-CIRCLE* is load-bearing.
  :perform (test-op (op c)
             (declare (ignore op c))
             (let ((*print-circle* t)
                   (filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
               (unless (uiop:symbol-call
                        :cl-weave '#:run-all
                        :reporter :spec
                        :name-filter (when (and filter (plusp (length filter))) filter)
                        :max-workers 1
                        :pass-with-no-tests nil)
                 (error "nerimux-model test suite failed")))))

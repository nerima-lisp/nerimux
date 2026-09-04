;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-renderer"
  :description "PRESENTATION frame rendering for nerimux: panes, status bar, workspace overview, magit-style views"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-model" "nerimux-terminal" "nerimux-picker"
               :cl-tui-kit/core :cl-tui-kit/ansi :cl-tui-kit/layout :cl-tui-kit/widgets
               :cl-tty-kit :cl-regex-kit :cl-concurrent-kit)
  :pathname "src"
  ;; Order carried over verbatim from nerimux.asd's presentation/renderer
  ;; module: the ANSI primitives and theme palette first, then the workspace
  ;; helpers (which depend on no pane compositor -- their position states that
  ;; boundary), then the pane compositor, then the tui-kit surface helpers the
  ;; three magit views need, with the transient before the status view because
  ;; the status frame draws the transient panel into its own bottom region.
  :serial t
  :components (
               (:file "package")
               (:file "renderer-format-definitions")
               (:file "renderer-format")
               (:file "renderer-style-data")
               (:file "renderer-style")
               (:file "renderer-workspace-status-title")
               (:file "renderer-workspace-command-line")
               (:file "renderer-workspace-tree-data")
               (:file "renderer-workspace-tree-entries")
               (:file "renderer-workspace-tree-layout")
               (:file "renderer-workspace-tree")
               (:file "renderer-workspace-key-panel")
               (:file "renderer-workspace")
               (:file "renderer-pane-selection")
               (:file "renderer-statusbar-layout")
               (:file "renderer-pane-search")
               (:file "renderer-pane-copy-mode-overlay")
               (:file "renderer-pane")
               (:file "renderer-borders")
               (:file "renderer-statusbar")
               (:file "renderer-compose-protocols")
               (:file "renderer-compose-overlay")
               (:file "renderer-compose-effects")
               (:file "renderer-compose")
               (:file "renderer-tui-kit-frame-grid-core")
               (:file "renderer-tui-kit-frame-grid-parser")
               (:file "renderer-tui-kit-frame-grid-output")
               (:file "renderer-tui-kit-frame-grid")
               (:file "renderer-tui-kit-widgets")
               (:file "renderer-tui-kit")
               (:file "renderer-tui-kit-confirm-view")
               (:file "renderer-tui-kit-help")
               (:file "renderer-tui-kit-transient")
               (:file "renderer-process-log")
               (:file "renderer-workspace-status-data")
               (:file "renderer-workspace-status-render")
               (:file "renderer-workspace-status")               )
  :in-order-to ((test-op (test-op "nerimux-renderer/test"))))

(defsystem "nerimux-renderer/test"
  :description "Test suite for nerimux-renderer"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; All three edges mirror nerimux-renderer's own :depends-on.
  :depends-on ("nerimux-renderer" "nerimux-model/test" "nerimux-terminal/test"
               "nerimux-picker/test" (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-renderer-fixtures")
               (:file "helpers-render-output")
               (:file "renderer-format-tests")
               (:file "renderer-format-tests-b")
               (:file "renderer-pane-tests")
               (:file "renderer-pane-tests-b")
               (:file "renderer-pane-tests-c")
               (:file "renderer-tests")
               (:file "renderer-tests-b")
               (:file "renderer-tests-c")
               (:file "renderer-tests-e")
               (:file "renderer-tests-g")
               (:file "renderer-statusbar-layout-tests")
               (:file "renderer-compose-effects-tests")
               (:file "renderer-workspace-status-tokens-tests")
               (:file "renderer-workspace-clip-tests")
               (:file "renderer-workspace-tree-tests")
               (:file "renderer-workspace-tree-panels-tests")
               (:file "renderer-workspace-command-completion-tests")
               (:file "renderer-statusbar-workspace-tests")
               (:file "renderer-copy-mode-position-tests")
               (:file "renderer-tui-kit-min-size-tests")
               (:file "renderer-tui-kit-tests")
               (:file "renderer-tui-kit-help-tests")
               (:file "renderer-transient-tests")
               (:file "renderer-workspace-status-tests")               )
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
                 (error "nerimux-renderer test suite failed")))))

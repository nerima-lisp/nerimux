;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-commands"
  :description "APPLICATION pane and window commands for nerimux, including the copy-mode cluster"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; nerimux-ports rather than nerimux-pty for the PTY teardown: commands-core
  ;; calls nerimux/ports:close-pty, the shared PTY contract.
  :depends-on ("nerimux-model" "nerimux-terminal" "nerimux-ports"
               :cl-parser-kit :cl-regex-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "commands-core")
               (:file "commands-copy-mode")      ; copy-mode core: enter/exit, scroll, prompts, selection state
               (:file "commands-copy-mode-cursor") ; cursor movement and viewport edge scrolling
               (:file "commands-copy-mode-selection") ; selection bounds and text extraction helpers
               (:file "commands-copy-mode-clip") ; rectangle selection text, yank, copy-pipe, append-selection
               (:file "commands-copy-mode-virtual") ; virtual-row helpers shared by search and selection
               (:file "commands-copy-mode-search") ; search-forward/backward, search-next/prev
               (:file "commands-tokenizer"))     ; shell-style command-string tokeniser
  :in-order-to ((test-op (test-op "nerimux-commands/test"))))

(defsystem "nerimux-commands/test"
  :description "Test suite for nerimux-commands"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; Both edges mirror nerimux-commands' own :depends-on.
  :depends-on ("nerimux-commands" "nerimux-model/test" "nerimux-terminal/test"
               :cl-concurrent-kit :cl-date-kit (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-copy-mode-fixtures")
               (:file "commands-tests")
               (:file "commands-pane-lifecycle-tests") ; close-pane-pty: fd/pid order, error swallowing
               (:file "commands-tests-e")
               (:file "commands-tests-f")
               (:file "commands-tests-m")
               (:file "commands-tests-n")
               (:file "commands-tests-k")
               (:file "commands-tests-g")
               (:file "commands-tests-h")
               (:file "commands-window-navigation-tests") ; find-window and next/previous/last-window command behavior
               (:file "commands-tests-c")
               (:file "commands-tests-o")
               (:file "commands-tests-j")
               (:file "commands-tests-l")
               (:file "commands-tests-i")
               (:file "commands-copy-navigation-tests")) ; copy-mode search next/prev/forward/backward guards
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
                 (error "nerimux-commands test suite failed")))))

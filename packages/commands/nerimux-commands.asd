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
  :depends-on ("nerimux-model" "nerimux-terminal" "nerimux-ports"
               :cl-parser-kit :cl-regex-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "commands-core")
               (:file "commands-copy-mode")
               (:file "commands-copy-mode-cursor")
               (:file "commands-copy-mode-selection")
               (:file "commands-copy-mode-clip")
               (:file "commands-copy-mode-virtual")
               (:file "commands-copy-mode-search")
               (:file "commands-tokenizer"))
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
  :depends-on ("nerimux-commands" "nerimux-model/test" "nerimux-terminal/test"
               :cl-concurrent-kit :cl-date-kit (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-copy-mode-fixtures")
               (:file "commands-tests")
               (:file "commands-pane-lifecycle-tests")
               (:file "commands-tests-e")
               (:file "commands-tests-f")
               (:file "commands-tests-m")
               (:file "commands-tests-n")
               (:file "commands-tests-k")
               (:file "commands-tests-g")
               (:file "commands-tests-h")
               (:file "commands-window-navigation-tests")
               (:file "commands-tests-c")
               (:file "commands-tests-o")
               (:file "commands-tests-j")
               (:file "commands-tests-l")
               (:file "commands-tests-i")
               (:file "commands-copy-navigation-tests"))
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

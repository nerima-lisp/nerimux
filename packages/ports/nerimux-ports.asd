;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-ports"
  :description "DOMAIN port abstractions for nerimux: the boundary infrastructure adapters install into"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ()
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "posix-port")
               (:file "pty-port"))
  :in-order-to ((test-op (test-op "nerimux-ports/test"))))

(defsystem "nerimux-ports/test"
  :description "Test suite for nerimux-ports"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-ports" (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "helpers-posix-environment")
               (:file "helpers-pipe-fixtures")
               (:file "posix-port-tests"))
  ;; See packages/text/nerimux-text.asd for why this form is repeated per unit
  ;; rather than shared, and why *PRINT-CIRCLE* is load-bearing rather than
  ;; cosmetic.
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
                 (error "nerimux-ports test suite failed")))))

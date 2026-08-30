;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-pty"
  :description "INFRASTRUCTURE pseudo-terminal adapter for nerimux: spawn, raw mode, fd IO"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; pty.lisp writes into nerimux/ports' port variables; the adapter depends on
  ;; the abstraction, never the other way round.
  :depends-on ("nerimux-ports"
               :cl-tty-kit :cl-process-kit :cl-codec-kit
               :cl-concurrent-kit :cl-date-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "pty-ffi")       ; FFI declarations and platform constants
               (:file "pty-rawmode")   ; terminal raw mode management
               (:file "pty"))          ; PTY lifecycle + install-pty-port adapter
  :in-order-to ((test-op (test-op "nerimux-pty/test"))))

(defsystem "nerimux-pty/test"
  :description "Test suite for nerimux-pty"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; nerimux-ports/test supplies the POSIX-environment and pipe fixtures. That
  ;; edge is legal precisely because nerimux-pty depends on nerimux-ports: a
  ;; unit's test system may only reach a test system its own unit could reach.
  :depends-on ("nerimux-pty" "nerimux-ports/test" (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "pty-ffi-tests")
               (:file "pty-rawmode-tests")
               (:file "pty-tests"))
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
                 (error "nerimux-pty test suite failed")))))

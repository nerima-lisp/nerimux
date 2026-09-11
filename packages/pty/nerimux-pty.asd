(in-package #:asdf-user)

(defsystem "nerimux-pty"
  :description "INFRASTRUCTURE pseudo-terminal operations for nerimux: spawn, raw mode, fd IO"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-ports"
               :cl-tty-kit :cl-process-kit :cl-codec-kit
               :cl-concurrent-kit :cl-date-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "pty-ffi")
               (:file "pty-rawmode")
               (:file "pty-process")
               (:file "pty-io")
               (:file "pty-select")
               (:file "pty-terminal")
               (:file "pty"))
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
  :depends-on ("nerimux-pty" "nerimux-ports/test" (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "pty-ffi-tests")
               (:file "pty-rawmode-tests")
               (:file "pty-tests"))
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

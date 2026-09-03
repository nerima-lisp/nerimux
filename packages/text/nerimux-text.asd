;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-text"
  :description "FOUNDATION string-to-value coercions for nerimux, depending on nothing"
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
  :components ((:file "package") (:file "text-parse"))
  :in-order-to ((test-op (test-op "nerimux-text/test"))))

(defsystem "nerimux-text/test"
  :description "Test suite for nerimux-text"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-text" (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "text-parse-tests"))
  ;; Duplicated across every unit rather than shared, for the reason
  ;; tests/pty/helpers.lisp already gives: a unit's test system loading only its
  ;; own components is the point of the split, and a shared runner system would
  ;; be one more edge every unit has to declare.
  ;;
  ;; *PRINT-CIRCLE* is not a formatting preference. The domain model is
  ;; legitimately cyclic, and a reporter rendering a failed assertion's value
  ;; with ~S exhausts the control stack without it -- taking the whole run's
  ;; results with it, not just the one failure. See tests/suite.lisp.
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
                 (error "nerimux-text test suite failed")))))

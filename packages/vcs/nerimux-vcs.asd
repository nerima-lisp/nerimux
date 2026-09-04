;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

(defsystem "nerimux-vcs"
  :description "INFRASTRUCTURE VCS operations for nerimux: ghq discovery, worktree operations, status inspection"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-model" :cl-vcs-kit :cl-concurrent-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "vcs")
               (:file "vcs-catalog")
               (:file "vcs-worktree-operations")
               (:file "vcs-worktree-async-operations")
               (:file "vcs-status")
               (:file "vcs-async-operations")
               (:file "vcs-fetch")
               (:file "vcs-inspect")
               (:file "vcs-operations")
               ;; Last: the write operations need %REPOSITORY-CHECKED-HANDLE (the
               ;; vcs-kit:make-repository construction extracted from
               ;; vcs-worktree-operations.lisp's %REV-PARSE) and
               ;; %SANITIZE-RETAINED-TEXT from vcs-inspect.lisp. Passing the
               ;; other repository handle type fails SILENTLY here -- the type
               ;; error is swallowed and the operation returns NIL forever -- so
               ;; this is a load-order dependency, not a convenience.
               (:file "vcs-git-write"))
  :in-order-to ((test-op (test-op "nerimux-vcs/test"))))

(defsystem "nerimux-vcs/test"
  :description "Test suite for nerimux-vcs"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  ;; nerimux-ports/test carries the fdefinition-swap fixture; the edge is legal
  ;; because nerimux-vcs depends on nerimux-model, which depends on
  ;; nerimux-ports.
  :depends-on ("nerimux-vcs" "nerimux-ports/test"
               :cl-host-kit :cl-process-kit
               (:version "cl-weave" "1.3.0"))
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "vcs-tests")
               (:file "vcs-fetch-dedup-tests") ; R7.1: one fetch in flight per target
               (:file "vcs-worktree-path-tests") ; R7.2: timestamp-sha path, -2/-3 on collision
               (:file "vcs-operations-tests")
               (:file "vcs-async-operations-tests")
               (:file "vcs-inspect-tests"))
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
                 (error "nerimux-vcs test suite failed")))))

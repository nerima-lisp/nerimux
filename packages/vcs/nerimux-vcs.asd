(in-package #:asdf-user)

(defsystem "nerimux-vcs"
  :description "INFRASTRUCTURE VCS operations for nerimux: ghq discovery, worktree operations, status inspection"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.4.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-model" "nerimux-text" :cl-vcs-kit :cl-concurrent-kit :cl-log-kit)
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "vcs")
               (:file "vcs-catalog")
               (:file "vcs-directory-resolution")
               (:file "vcs-path-operations")
               (:file "vcs-worktree-operations")
               (:file "vcs-worktree-async-operations")
               (:file "vcs-worktree-status-refresh")
               (:file "vcs-status")
               (:file "vcs-async-operations")
               (:file "vcs-fetch")
               (:file "vcs-inspect")
               (:file "vcs-operations")
               (:file "vcs-clone")
               (:file "vcs-git-write"))
  :in-order-to ((test-op (test-op "nerimux-vcs/test"))))

(defsystem "nerimux-vcs/test"
  :description "Test suite for nerimux-vcs"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.4.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ("nerimux-vcs" "nerimux-ports/test"
               :cl-host-kit (:version "cl-process-kit" "3.4.0")
               (:version "cl-weave" "1.4.0"))
  :pathname "t"
  :serial t
  :components ((:file "package") (:file "test-worker-waits")
               (:file "vcs-value-tests")
               (:file "vcs-worktree-status-tests")
               (:file "vcs-tests")
               (:file "vcs-prune-tests")
               (:file "vcs-tests-workspace")
               (:file "vcs-tests-status")
               (:file "vcs-fetch-dedup-tests")
               (:file "vcs-worktree-path-tests")
               (:file "vcs-catalog-tests")
               (:file "vcs-operations-tests")
               (:file "vcs-command-tests")
               (:file "vcs-async-operations-tests")
               (:file "vcs-inspect-tests")
               (:file "vcs-clone-tests")
               (:file "vcs-clone-path-boundary-tests"))
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

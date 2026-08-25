(in-package #:nerimux/pty-test)

;;;; Entry point for the nerimux/pty-test suite.
;;;;
;;;; Every file in this system registers its own top-level (describe ...)
;;;; block as a side effect of loading (cl-weave, used natively -- same
;;;; convention as nerimux/test's RUN-TESTS in t/suite.lisp).  Because this
;;;; system loads only its own components, cl-weave's global registry holds
;;;; nothing but the suites this package registers, so RUN-ALL here runs
;;;; exactly the real-PTY suite and nothing else.

(defun %test-name-filter-from-environment ()
  (let ((filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
    (when (and filter (plusp (length filter)))
      filter)))

(defun run-pty-tests ()
  "Run every registered real-PTY suite SEQUENTIALLY (single worker) through
cl-weave, report the results, and signal an error (non-zero exit) on any
failure or empty suite.  Run with: (asdf:test-system \"nerimux/pty-test\")"
  ;; *PRINT-CIRCLE* for the same reason t/suite.lisp binds it, and this suite
  ;; needs it at least as much: its cases build real sessions, so a failed
  ;; assertion here is MORE likely to hold a PANE or WORKTREE whose parent
  ;; links form a cycle.  Without it the structure printer recurses until the
  ;; control stack is exhausted and the process dies mid-report, losing every
  ;; other result in the run.  See the full note in t/suite.lisp.
  ;;
  ;; Duplicated rather than shared because nerimux/pty-test deliberately loads
  ;; only its own components (that isolation is the point of the split), which
  ;; is the same reason the helpers in t/pty/helpers.lisp are duplicates.
  (unless (let ((*print-circle* t))
            (cl-weave:run-all
             :reporter :spec
             :name-filter (%test-name-filter-from-environment)
             :max-workers 1
             :pass-with-no-tests nil))
    (error "nerimux/pty-test suite failed"))
  t)

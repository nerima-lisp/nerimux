(in-package #:nerimux/pty-test)

(defun %test-name-filter-from-environment ()
  (let ((filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
    (when (and filter (plusp (length filter)))
      filter)))

(defun run-pty-tests ()
  "Run every registered real-PTY suite SEQUENTIALLY (single worker) through
cl-weave, report the results, and signal an error (non-zero exit) on any
failure or empty suite.  Run with: (asdf:test-system \"nerimux/pty-test\")"
  (unless (let ((*print-circle* t))
            (cl-weave:run-all
             :reporter :spec
             :name-filter (%test-name-filter-from-environment)
             :max-workers 1
             :pass-with-no-tests nil))
    (error "nerimux/pty-test suite failed"))
  t)

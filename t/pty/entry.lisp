(in-package #:nerimux/pty-test)

;;;; Entry point for the nerimux/pty-test suite.
;;;;
;;;; Every file in this system registers its own top-level (describe ...)
;;;; block as a side effect of loading (cl-weave, used natively -- same
;;;; convention as nerimux/test's RUN-TESTS in t/suite.lisp).  Because this
;;;; system never loads any of nerimux/test's ~280 other files, cl-weave's
;;;; global registry holds nothing but the suites this package's files
;;;; register, so RUN-ALL here runs exactly the real-PTY suite and nothing
;;;; else.

(defun run-pty-tests ()
  "Run every registered real-PTY suite SEQUENTIALLY (single worker) through
cl-weave, report the results, and signal an error (non-zero exit) on any
failure or empty suite.  Run with: (asdf:test-system \"nerimux/pty-test\")"
  (unless (cl-weave:run-all :reporter :spec :max-workers 1
                             :pass-with-no-tests nil)
    (error "nerimux/pty-test suite failed"))
  t)

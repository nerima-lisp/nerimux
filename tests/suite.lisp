(in-package #:nerimux/test)

;;;; Top-level test runner, on cl-weave.
;;;;
;;;; Every file registers its own top-level (describe ...) block directly with
;;;; cl-weave.  RUN-TESTS walks the whole suite tree with cl-weave's runner in
;;;; single-worker (sequential) mode and fails on any failure.
;;; Sequential execution is REQUIRED — not a performance choice.  Integration
;;; suites share global session, runtime, socket, and PTY state; running them
;;; concurrently would leave reader/status/background threads from one test
;;; visible to another.  Each test that spawns a background thread/server
;;; joins it itself (see WITH-LOOP-STATE in helpers-loop-fixtures.lisp), so
;;; isolation does not depend on suite boundaries or execution order.
(defun %test-name-filter-from-environment ()
  (let ((filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
    (when (and filter (plusp (length filter)))
      filter)))

;;; *PRINT-CIRCLE* is not a formatting preference here — it is what keeps a
;;; single failing assertion from destroying the entire run.
;;;
;;; The domain model is legitimately cyclic: REPOSITORY-ORGANIZATION points at
;;; an ORGANIZATION whose ORGANIZATION-REPOSITORIES contains that same
;;; REPOSITORY (likewise WORKTREE/PANE and their parents).  That is the
;;; intended aggregate shape, not a bug.  But a reporter printing a failed
;;; assertion's ACTUAL value renders it with ~S, and SBCL's structure pretty
;;; printer has no cycle detection unless *PRINT-CIRCLE* is true: it recurses
;;; through SB-PRETTY::CALL-LOGICAL-BLOCK-PRINTER until "Control stack
;;; exhausted" kills the process.
;;;
;;; The consequence is what makes this severe.  The process dies mid-report, so
;;; the run yields NO results at all — not "one test failed", but every other
;;; test's outcome lost, and a `nix flake check' that reports a crash instead of
;;; the assertion that actually failed.  One ordinary failure takes down the
;;; whole gate.
;;;
;;; Reproduced directly (SBCL 2.6.6): a two-struct A<->B cycle through
;;; (format nil "~S" x) with *PRINT-CIRCLE* NIL exhausts the control stack,
;;; and prints as #1=#S(...) with it bound to T.
;;;
;;; Deliberately NOT also binding *PRINT-LEVEL*/*PRINT-LENGTH*: those would
;;; bound output size, but they truncate by hiding structure, and the hidden
;;; part is exactly the difference that made the assertion fail.  Cycle
;;; detection costs no information; truncation does.
;;;
;;; :MAX-WORKERS 1 is what makes one dynamic binding sufficient — the reporter
;;; runs on this thread.  A future move to real workers must rebind this inside
;;; each worker, or the crash returns on whichever thread reports.
(defmacro with-cycle-safe-printing (&body body)
  "Run BODY with the printer able to render the cyclic domain model."
  `(let ((*print-circle* t))
     ,@body))

(defun run-tests ()
  "Run every registered suite SEQUENTIALLY (single worker) through cl-weave,
report the results, and signal an error (non-zero exit under Nix) on any
failure or empty suite."
  (unless 
      (with-cycle-safe-printing
       (cl-weave:run-all :reporter
                         :spec
                         :name-filter
                         (%test-name-filter-from-environment)
                         :max-workers
                         1
                         :pass-with-no-tests
                         nil))
    (error "nerimux test suite failed"))
  t)

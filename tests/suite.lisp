(in-package #:nerimux/test)

(defun %test-name-filter-from-environment ()
  (let ((filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
    (when (and filter (plusp (length filter)))
      filter)))

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

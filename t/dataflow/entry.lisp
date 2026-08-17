;;;; Entry point for the cl-dataflow-kit copy-mode lifecycle cl-weave suite.
;;;;
;;;; The suite registers as a side effect of loading copy-mode-lifecycle-tests
;;;; (the top-level `describe' form runs at load time), so the runner just
;;;; walks the global registry, mirroring t/weave/entry.lisp.

(in-package #:cl-tmux/dataflow-tests)

(defun run-dataflow-tests (&key (reporter :spec))
  "Run the cl-tmux cl-dataflow-kit copy-mode lifecycle suite; return T on success."
  (cl-weave:run-all :reporter reporter))

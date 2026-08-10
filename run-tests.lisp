;;;; Root test entry point for cl-tmux.
;;;;
;;;;   sbcl --script run-tests.lisp
;;;;
;;;; This is the single Lisp-level entry point required by PACKAGE_STANDARD.md.
;;;; flake.nix drives every `checks.*` derivation and `nix run .#test` through
;;;; it, so the command a contributor runs by hand and the command CI runs are
;;;; the same one.
;;;;
;;;; Which suite runs is chosen by CL_TMUX_TEST_SYSTEM, defaulting to the main
;;;; suite. The three registered suites are:
;;;;
;;;;   cl-tmux/test      the full unit + integration suite (checks.default)
;;;;   cl-tmux/weave     the cl-prolog reasoning read-model (checks.weave)
;;;;   cl-tmux/dataflow  the copy-mode lifecycle read-model (checks.dataflow)
;;;;
;;;; Every one of them defines its own ASDF :perform (test-op ...) that signals
;;;; an error on failure, so dispatching through ASDF:TEST-SYSTEM keeps the
;;;; pass/fail contract in the .asd rather than duplicating a runner per suite.

(require :asdf)

;;; ASDF has to be told where this checkout and its sibling libraries are.
;;; Sibling packages are consumed purely as source (see flake.nix), so they go
;;; on the central registry rather than through nixpkgs Lisp packaging.
;;;
;;; CL_TMUX_SIBLING_REGISTRY is a colon-separated list of sibling source roots
;;; supplied by flake.nix. It is optional: an unset value leaves the registry
;;; alone, which is what a developer wants when the siblings are already on
;;; CL_SOURCE_REGISTRY (the nixpkgs sbcl wrapper only ever *prefixes* that
;;; variable, so an outer value survives).
(push (uiop:pathname-directory-pathname *load-truename*)
      asdf:*central-registry*)

(dolist (dir (uiop:split-string (or (uiop:getenv "CL_TMUX_SIBLING_REGISTRY") "")
                                :separator ":"))
  (unless (string= dir "")
    (push (truename (uiop:ensure-directory-pathname dir))
          asdf:*central-registry*)))

(let ((system (or (uiop:getenv "CL_TMUX_TEST_SYSTEM") "cl-tmux/test")))
  (format t "~&Running test system ~A~%" system)
  (finish-output)
  (handler-case (asdf:test-system system)
    ;; --script already exits non-zero on an unhandled error, but it prints a
    ;; raw backtrace. Catching it keeps the failure line first in the CI log,
    ;; which is the part `nix flake check --print-build-logs` shows on failure.
    (error (e)
      (format *error-output* "~&TESTS FAILED (~A): ~A~%" system e)
      (finish-output *error-output*)
      (uiop:quit 1))))

(uiop:quit 0)

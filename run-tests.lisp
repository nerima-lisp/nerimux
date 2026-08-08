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

(progn
  (defun %register-directory (directory)
    (pushnew (truename directory)
             asdf:*central-registry*
             :test (function equal)))
  (defun %bootstrap-sibling-directories ()
    (let ((registry (sb-ext:posix-getenv "CL_TMUX_SIBLING_REGISTRY")))
      (when (and registry (plusp (length registry)))
        (loop with start = 0
              for separator = (position #\: registry :start start)
              for directory = (subseq registry start separator)
              do (unless (string= directory "")
                   (%register-directory directory))
              if separator
                do (setf start (1+ separator))
              else
                do (return))))))

;;; ASDF has to be told where this checkout and its sibling libraries are.
;;; Sibling packages are consumed purely as source (see flake.nix), so they go
;;; on the central registry rather than through nixpkgs Lisp packaging.
;;;
;;; CL_TMUX_SIBLING_REGISTRY is a colon-separated list of sibling source roots
;;; supplied by flake.nix. It is optional: an unset value leaves the registry
;;; alone, which is what a developer wants when the siblings are already on
;;; CL_SOURCE_REGISTRY (the nixpkgs sbcl wrapper only ever *prefixes* that
;;; variable, so an outer value survives).
(progn
  (%register-directory
   (make-pathname :name nil :type nil :defaults *load-truename*))
  (%bootstrap-sibling-directories)
  (asdf:load-system "cl-host-kit"))

(progn
  (%register-directory (host-kit:pathname-directory-pathname *load-truename*))
  (dolist (dir (host-kit:split-string
                (or (host-kit:getenv "CL_TMUX_SIBLING_REGISTRY") "")
                :separator #\:))
    (unless (string= dir "")
      (%register-directory (host-kit:ensure-directory-pathname dir)))))

(let ((system (or (host-kit:getenv "CL_TMUX_TEST_SYSTEM") "cl-tmux/test")))
  (format t "~&Running test system ~A~%" system)
  (finish-output)
  (handler-case (asdf:test-system system)
    (error (condition)
      (format *error-output* "~&TESTS FAILED (~A): ~A~%" system condition)
      (finish-output *error-output*)
      (host-kit:quit 1))))

(host-kit:quit 0)

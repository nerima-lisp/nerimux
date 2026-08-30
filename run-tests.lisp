;;;; Root test entry point for nerimux.
;;;;
;;;;   sbcl --script run-tests.lisp
;;;;
;;;; This is the single Lisp-level entry point required by PACKAGE_STANDARD.md.
;;;; flake.nix drives every `checks.*` derivation and `nix run .#test` through
;;;; it, so the command a contributor runs by hand and the command CI runs are
;;;; the same one.
;;;;
;;;; Which suite runs is chosen by NERIMUX_TEST_SYSTEM, defaulting to the full
;;;; suite:
;;;;
;;;;   nerimux/test      the full unit + integration suite (checks.default)
;;;;   nerimux-vcs/test  focused VCS infrastructure suite, from packages/vcs/
;;;;   nerimux/pty-test  the real-PTY suite; needs /dev/ptmx, so it is an app
;;;;                     (nix run .#test-pty) and deliberately not a check
;;;;
;;;; It defines its own ASDF :perform (test-op ...) that signals
;;;; an error on failure, so dispatching through ASDF:TEST-SYSTEM keeps the
;;;; pass/fail contract in the .asd rather than duplicating a runner per suite.

(require :asdf)
(sb-impl::module-provide-contrib :sb-posix)
(asdf:register-preloaded-system "sb-posix")

;;; ASDF has to be told where this checkout and its sibling libraries are.
;;; Sibling packages are consumed purely as source (see flake.nix), so they go
;;; on the central registry rather than through nixpkgs Lisp packaging.
(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

;;; NERIMUX_SIBLING_REGISTRY is a colon-separated list of sibling source roots
;;; supplied by flake.nix. An unset value still permits dependencies explicitly
;;; registered by the invoking image, without scanning machine-global trees.
(push (uiop:pathname-directory-pathname *load-truename*)
      asdf:*central-registry*)

;;; Each in-repo unit lives in packages/<name>/ and carries its own .asd. The
;;; central registry does not recurse, so registering the repository root alone
;;; leaves every unit unresolvable when it is asked for by its own name --
;;; (asdf:load-system "nerimux-terminal") never reads nerimux.asd, because ASDF
;;; resolves a primary system from the .asd named after it.
(dolist (dir (directory (merge-pathnames
                         "packages/*/"
                         (uiop:pathname-directory-pathname *load-truename*))))
  (push dir asdf:*central-registry*))

(dolist (dir (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                                :separator ":"))
  (unless (string= dir "")
    (push (truename (uiop:ensure-directory-pathname dir))
          asdf:*central-registry*)))

(let ((system (or (uiop:getenv "NERIMUX_TEST_SYSTEM") "nerimux/test")))
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

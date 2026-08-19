;;;; sb-cover coverage report entry point for nerimux.
;;;;
;;;;   sbcl --script scripts/coverage.lisp [output-dir]
;;;;
;;;; Mirrors run-tests.lisp's registry setup (this project + its
;;;; NERIMUX_SIBLING_REGISTRY siblings on ASDF's central registry), but loads
;;;; nerimux/test under sb-cover instrumentation instead of running it
;;;; straight. sb-cover only instruments code compiled AFTER
;;;; sb-cover:store-coverage-data is declared via restrict-compiler-policy, so
;;;; that declaration must run before nerimux/test (and nerimux underneath it)
;;;; is loaded at all -- running the suite with :coverage t against an
;;;; already-loaded or fasl-cached image silently instruments nothing and
;;;; reports a misleading 100% (coverage-percentage treats a 0/0 total as
;;;; 100.0).
;;;;
;;;; nix build .#coverage-report runs this script inside the Nix sandbox,
;;;; where the full suite is known to complete cleanly (see checks.default);
;;;; the interactive devShell nerimux-coverage helper calls this same script.

(require :asdf)
(require :sb-cover)

(sb-ext:restrict-compiler-policy 'sb-cover:store-coverage-data 3)

(push (truename (merge-pathnames #P"../" (uiop:pathname-directory-pathname *load-truename*)))
      asdf:*central-registry*)

(dolist (dir (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                                :separator ":"))
  (unless (string= dir "")
    (push (truename (uiop:ensure-directory-pathname dir))
          asdf:*central-registry*)))

(asdf:load-system "nerimux/test")

(let ((report-dir (or (second sb-ext:*posix-argv*) "coverage-report/")))
  (unless (cl-weave:run-all :reporter :spec :max-workers 1
                            :coverage t :coverage-reset t
                            :coverage-report-directory report-dir)
    (error "nerimux test suite failed under coverage instrumentation"))
  (format t "~&Coverage report: ~A~%" report-dir))

(uiop:quit 0)

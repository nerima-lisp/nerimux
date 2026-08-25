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

(defconstant +coverage-test-timeout-ms+ 2700000)

;; These files contain declarations, compile-time fact constructors, or static
;; lookup values only. Their consumers remain covered; counting the definition
;; forms as executable behavior would make the percentage measure source
;; representation instead of product behavior.
(defparameter *coverage-excluded-source-files*
  '("src/bootstrap/main-startup-flags.lisp"
    "src/bootstrap/package.lisp"
    "src/domain/terminal/csi-replies-definitions.lisp"
    "src/domain/terminal/modes-ansi-sm-rm-definitions.lisp"
    "src/domain/terminal/modes-charset-definitions.lisp"
    "src/domain/terminal/modes-dec-pm-definitions.lisp"
    "src/domain/terminal/screen-data.lisp"
    "src/infrastructure/pty/pty-ffi.lisp"
    "src/presentation/renderer/renderer-format-definitions.lisp"
    "src/presentation/renderer/renderer-style-data.lisp"
    "src/presentation/renderer/renderer-style.lisp"))

(sb-ext:restrict-compiler-policy 'sb-cover:store-coverage-data 3)

(proclaim '(optimize (sb-cover:store-coverage-data 3)))

(defmethod asdf:perform :around ((operation asdf:compile-op)
                                 (component asdf:cl-source-file))
  (declare (ignore operation component))
  (proclaim '(optimize (sb-cover:store-coverage-data 3)))
  (unwind-protect
       (call-next-method)
    (proclaim '(optimize (sb-cover:store-coverage-data 0)))))

(defparameter *nerimux-project-root*
  (truename (merge-pathnames #P"../"
                             (uiop:pathname-directory-pathname *load-truename*))))

(defparameter *nerimux-source-root*
  (truename (merge-pathnames #P"src/" *nerimux-project-root*)))

(push *nerimux-project-root* asdf:*central-registry*)

(dolist (dir (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                                :separator ":"))
  (unless (string= dir "")
    (push (truename (uiop:ensure-directory-pathname dir))
          asdf:*central-registry*)))

(asdf:load-system "nerimux/test" :force t)

(let* ((excluded-source-pathnames
         (mapcar (lambda (relative-path)
                   (truename (merge-pathnames (pathname relative-path)
                                              *nerimux-project-root*)))
                 *coverage-excluded-source-files*))
       (report-dir (uiop:ensure-directory-pathname
                    (or (second sb-ext:*posix-argv*) "coverage-report/")))
       (report-index (merge-pathnames "cover-index.html" report-dir)))
  ;; cl-weave resets SB-COVER immediately before entering the test thunk. The
  ;; test system's dependency may already have been compiled while registering
  ;; its suites, so force-load the production system after an explicit reset to
  ;; make the coverage report describe the current source rather than cached
  ;; uninstrumented fasls.
  (cl-weave:reset-coverage)
  (asdf:load-system "nerimux" :force t)
  (unless (cl-weave:run-all :reporter :spec :max-workers 1
                            :pass-with-no-tests nil
                            :timeout-ms +coverage-test-timeout-ms+
                            :coverage t :coverage-reset nil
                            :coverage-include-pathnames (list *nerimux-source-root*)
                            :coverage-exclude-pathnames excluded-source-pathnames
                            :coverage-minimum-expression 100
                            :coverage-minimum-branch 100
                            :coverage-report-directory report-dir)
    (error "nerimux test suite failed under coverage instrumentation"))
  (unless (and (probe-file report-index)
               (with-open-file (stream report-index
                                       :direction :input
                                       :element-type '(unsigned-byte 8))
                 (plusp (file-length stream))))
    (error "coverage run did not produce a non-empty ~A" report-index))
  (format t "~&Coverage report: ~A~%" report-dir))

(uiop:quit 0)

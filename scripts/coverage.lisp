;;;; sb-cover coverage report entry point for cl-tmux.
;;;;
;;;;   sbcl --script scripts/coverage.lisp [output-dir]
;;;;
;;;; Mirrors run-tests.lisp's registry setup (this project + its
;;;; CL_TMUX_SIBLING_REGISTRY siblings on ASDF's central registry), but loads
;;;; cl-tmux/test under sb-cover instrumentation instead of running it
;;;; straight. sb-cover only instruments code compiled AFTER
;;;; sb-cover:store-coverage-data is declared via restrict-compiler-policy, so
;;;; that declaration must run before cl-tmux/test (and cl-tmux underneath it)
;;;; is loaded at all -- running the suite with :coverage t against an
;;;; already-loaded or fasl-cached image silently instruments nothing and
;;;; reports a misleading 100% (coverage-percentage treats a 0/0 total as
;;;; 100.0).
;;;;
;;;; nix build .#coverage-report runs this script inside the Nix sandbox,
;;;; where the full suite is known to complete cleanly (see checks.default);
;;;; the interactive devShell cl-tmux-coverage helper calls this same script.

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
(require :sb-cover)

(sb-ext:restrict-compiler-policy 'sb-cover:store-coverage-data 3)

(progn (%register-directory (make-pathname :name nil :type nil :defaults *load-truename*)) (%bootstrap-sibling-directories) (asdf:load-system "cl-host-kit"))

(progn (%register-directory (merge-pathnames #P"../" (host-kit:pathname-directory-pathname *load-truename*))) (dolist (dir (host-kit:split-string (or (host-kit:getenv "CL_TMUX_SIBLING_REGISTRY") "") :separator #\:)) (unless (string= dir "") (%register-directory (host-kit:ensure-directory-pathname dir)))))

(progn (asdf:compile-system "cl-tmux" :force t) (dolist (system '("cl-tmux/test" "cl-tmux/weave" "cl-tmux/dataflow")) (asdf:load-system system :force t)))

(let* ((report-dir
         (host-kit:ensure-directory-pathname
          (or (second sb-ext:*posix-argv*) "coverage-report/")))
       (source-root (truename (merge-pathnames #P"../src/"
                                                (host-kit:pathname-directory-pathname
                                                 *load-truename*))))
       (report-path (merge-pathnames #P"cover-index.html" report-dir)))
  (labels ((coverage-minimum (environment-name default)
             (let ((value (host-kit:getenv environment-name)))
               (if (and value (plusp (length value)))
                   (let ((minimum (ignore-errors
                                    (parse-integer value :junk-allowed nil))))
                     (unless (and minimum (<= 0 minimum 100))
                       (error "~A must be an integer from 0 through 100, got ~S"
                              environment-name value))
                     minimum)
                   default))))
    (unless (cl-weave:run-all
              :reporter :spec
              :max-workers 1
              :pass-with-no-tests nil
              :coverage t
              :coverage-reset t
              :coverage-report-directory report-dir
              :coverage-include-pathnames (list source-root)
              :coverage-minimum-expression
              (coverage-minimum "CL_TMUX_COVERAGE_MINIMUM_EXPRESSION" 87)
              :coverage-minimum-branch
              (coverage-minimum "CL_TMUX_COVERAGE_MINIMUM_BRANCH" 83))
      (error "cl-tmux test suite failed under coverage instrumentation"))
    (unless (probe-file report-path)
      (error "Coverage report was not generated: ~A" report-path))
    (with-open-file (stream report-path)
      (let ((contents (make-string (file-length stream))))
        (read-sequence contents stream)
        (when (search "No code coverage data found" contents)
          (error "Coverage report contains no instrumented code: ~A" report-path))))
    (format t "~&Coverage report: ~A~%" report-dir)))

(host-kit:quit 0)

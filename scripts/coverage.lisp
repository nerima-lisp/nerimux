(require :asdf)

(require :sb-cover)

(asdf:load-system "sb-cover")

(defconstant +coverage-test-timeout-ms+
  2700000)

(defun %coverage-test-name-filter ()
  (let ((filter (uiop:getenv "CL_WEAVE_TEST_FILTER")))
    (cond ((null filter) nil)
          ((string= filter "") nil)
          (t filter))))

(defun %ensure-full-coverage (statistics)
  (loop for (kind covered-key total-key) in '((:expression :expression-covered
                                                           :expression-total)
                                              (:branch :branch-covered
                                                       :branch-total))
        for covered = (getf statistics covered-key)
        for total = (getf statistics total-key)
        unless (= covered total)
          do (error "Coverage threshold failed for ~A: ~D/~D covered."
                    kind
                    covered
                    total))
  statistics)

(defparameter *coverage-excluded-source-files*
  '("src/main-startup-flags.lisp"
    "src/main-startup-data.lisp"
    "src/main-startup-socket-data.lisp"
    "src/main-startup-socket-macros.lisp"
    "src/runtime-reader-data.lisp"
    "src/server-data.lisp"
    "src/workspace-window-data.lisp"
    "src/server-multi-dispatch-prefix-data.lisp"
    "src/server-multi-dispatch-tree-filter-data.lisp"
    "src/server-multi-dispatch-command-input-data.lisp"
    "src/runtime-data.lisp"
    "src/package.lisp"
    "src/server-multi-state.lisp"
    "src/server-multi-transient-data.lisp"
    "src/server-multi-data.lisp"
    "src/server-dispatch-macros.lisp"
    "packages/terminal/src/csi-replies-definitions.lisp"
    "packages/terminal/src/csi-compose.lisp"
    "packages/terminal/src/csi-device-rules.lisp"
    "packages/terminal/src/csi-extended-rules.lisp"
    "packages/terminal/src/csi.lisp"
    "packages/terminal/src/csi-dispatch.lisp"
    "packages/terminal/src/char-write-definitions.lisp"
    "packages/terminal/src/cell.lisp"
    "packages/terminal/src/modes-ansi-sm-rm-definitions.lisp"
    "packages/terminal/src/modes-charset-definitions.lisp"
    "packages/terminal/src/modes-dec-pm-definitions.lisp"
    "packages/terminal/src/screen-data.lisp"
    "packages/model/src/window-definitions.lisp"
    "packages/model/src/layout-visitor.lisp"
    "packages/terminal/src/parser-core.lisp"
    "packages/ports/src/posix-port.lisp"
    "packages/pty/src/pty-ffi.lisp"
    "packages/renderer/src/renderer-format-definitions.lisp"
    "packages/renderer/src/renderer-style-data.lisp"
    "packages/renderer/src/renderer-style.lisp"))

#+sbcl
(sb-ext:restrict-compiler-policy 'sb-cover:store-coverage-data 3)

(proclaim '(optimize (sb-cover:store-coverage-data 3)))

(defmethod asdf:perform :around ((operation asdf:compile-op)
                                 (component asdf:cl-source-file))
  (declare (ignore operation component))
  (proclaim '(optimize (sb-cover:store-coverage-data 3)))
  (unwind-protect (call-next-method)
    (proclaim '(optimize (sb-cover:store-coverage-data 0)))))

(defparameter *nerimux-project-root*
  (truename
   (merge-pathnames #P"../" (uiop:pathname-directory-pathname *load-truename*))))

(defparameter *nerimux-source-root*
  (truename (merge-pathnames #P"src/" *nerimux-project-root*)))

(push *nerimux-project-root* asdf:*central-registry*)

(dolist 
    (dir
     (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                        :separator
                        ":"))
  (unless (string= dir "")
    (push (truename (uiop:ensure-directory-pathname dir))
          asdf:*central-registry*)))

(asdf:load-system "sb-cover")
(asdf:load-system "cl-weave")

(cl-weave:reset-coverage)

(asdf:clear-system "nerimux")

(asdf:compile-system "nerimux" :force t)

(asdf:load-system "nerimux" :force t)

(asdf:clear-system "nerimux/test")

(asdf:compile-system "nerimux/test" :force t)

(let* ((excluded-source-pathnames
         (mapcar (lambda (relative-path)
                   (let ((absolute (merge-pathnames (pathname relative-path)
                                                    *nerimux-project-root*)))
                     (or (probe-file absolute)
                         (error "~S names ~A, which does not exist. ~
                                 Update *coverage-excluded-source-files*."
                                '*coverage-excluded-source-files*
                                relative-path))))
                 *coverage-excluded-source-files*))
       (report-dir (uiop:ensure-directory-pathname
                    (or (first (uiop:command-line-arguments))
                        "coverage-report/")))
       (report-index (merge-pathnames "cover-index.html" report-dir))
       (enforce-thresholds-p
         (not (string= "1" (or (uiop:getenv "NERIMUX_COVERAGE_REPORT_ONLY") "")))))
  (asdf:load-system "nerimux/test")
  (unless (let ((*print-circle* t))
            (cl-weave:run-all :reporter :spec :max-workers 1
                              :pass-with-no-tests nil
                              :name-filter (%coverage-test-name-filter)
                              :timeout-ms +coverage-test-timeout-ms+
                              :coverage t :coverage-reset nil
                              :coverage-include-pathnames (list *nerimux-source-root*)
                              :coverage-exclude-pathnames excluded-source-pathnames
                              :coverage-report-directory report-dir))
    (error "nerimux test suite failed under coverage instrumentation"))
  (unless (and (probe-file report-index)
                 (with-open-file (stream report-index
                                       :element-type '(unsigned-byte 8))
                 (plusp (file-length stream))))
    (error "coverage run did not produce a non-empty ~A" report-index))
  (when enforce-thresholds-p
    (%ensure-full-coverage
     (cl-weave:coverage-statistics
      :include-pathnames (list *nerimux-source-root*)
      :exclude-pathnames excluded-source-pathnames)))
  (format t "~&Coverage report: ~A~%" report-dir))

(uiop:quit 0)

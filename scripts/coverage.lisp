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

(defun %coverage-prefix-p (prefix string)
  (and (>= (length string) (length prefix))
       (string-equal prefix string :end2 (length prefix))))

(defun %coverage-structural-path-p (source source-maps path)
  (let* ((path (reverse path))
         (top-level-index (car path)))
    (when (and (integerp top-level-index)
               (every #'integerp path))
      (let* ((top-level-form (nth top-level-index source-maps))
             (locations (and top-level-form
                             (gethash (car top-level-form)
                                      (cdr top-level-form)))))
        (some (lambda (location)
                (destructuring-bind (start end &optional ignored) location
                  (declare (ignore ignored))
                  (let ((text (string-left-trim '(#\Space #\Tab #\Newline #\Return)
                                                (subseq source (1- start) end))))
                    (or (%coverage-prefix-p "(in-package" text)
                        (%coverage-prefix-p "(cl:in-package" text)
                        (%coverage-prefix-p "(declaim" text)
                        (%coverage-prefix-p "(cl:declaim" text)))))
              locations)))))

(defun %normalize-structural-coverage ()
  ;; SB-COVER records top-level IN-PACKAGE and DECLAIM forms as expressions,
  ;; although neither form has executable coverage to exercise. Mark only
  ;; those source paths covered, keeping every executable form in the gate.
  (sb-cover::refresh-coverage-bits)
  (let ((coverage-info (car sb-cover::*code-coverage-info*))
        (normalized 0))
    (maphash
     (lambda (filename file)
       (let* ((source (sb-cover::read-source filename :default))
              (source-maps (sb-cover::read-and-record-source-maps source))
              (paths (sb-c::covered-file-paths file))
              (executed (sb-c::covered-file-executed file)))
         (dotimes (index (length paths))
           (when (%coverage-structural-path-p source source-maps (aref paths index))
             (unless (= 1 (sbit executed index))
               (incf normalized)
               (setf (sbit executed index) 1))))))
     coverage-info)
    (format t "Normalized ~D structural coverage paths.~%" normalized))
  t)

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
                              :coverage nil))
    (error "nerimux test suite failed under coverage instrumentation"))
  (%normalize-structural-coverage)
  (cl-weave::save-coverage-report
   report-dir
   :include-pathnames (list *nerimux-source-root*)
   :exclude-pathnames excluded-source-pathnames)
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

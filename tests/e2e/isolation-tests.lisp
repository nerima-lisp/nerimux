(load (merge-pathnames "helpers.lisp" *load-truename*))

(defun isolation-environment ()
  (mapcar (lambda (name) (cons name (sb-ext:posix-getenv name)))
          *e2e-environment-names*))

(defun assert-isolated-environment (root)
  (dolist (name *e2e-environment-names*)
    (let ((value (sb-ext:posix-getenv name)))
      (assert value)
      (if (string= name "SHELL")
          (assert (string= value "/bin/sh"))
          (progn
            (assert (eql 0 (search (namestring root) value)))
            (assert (probe-file value)))))))

(let ((passed 0) (failed 0))
  (flet ((run-case (name function)
           (handler-case
               (progn (funcall function)
                      (incf passed)
                      (format t "~&[isolation] PASS ~A~%" name))
             (error (condition)
               (incf failed)
               (format t "~&[isolation] FAIL ~A -- ~A~%" name condition)))))
    (run-case
     "normal return, multiple values, cleanup order"
     (lambda ()
       (let ((saved (isolation-environment)) (owned nil) (cleaned nil))
         (assert
          (equal '(17 :second nil)
                 (multiple-value-list
                  (call-with-isolated-e2e-environment
                   (lambda (root)
                     (setf owned root)
                     (assert-isolated-environment root)
                     (values 17 :second nil))
                   :cleanup (lambda (root)
                              (assert (equal root owned))
                              (assert (probe-file root))
                              (assert-isolated-environment root)
                              (setf cleaned t))))))
         (assert cleaned)
         (assert (not (probe-file owned)))
         (assert (equal saved (isolation-environment))))))
    (run-case
     "body error unwinds and restores"
     (lambda ()
       (let ((saved (isolation-environment)) (owned nil) (cleaned nil)
             (sentinel (make-condition 'simple-error :format-control "body sentinel")))
         (assert
          (eq sentinel
              (handler-case
                  (call-with-isolated-e2e-environment
                   (lambda (root) (setf owned root) (error sentinel))
                   :cleanup (lambda (root)
                              (assert-isolated-environment root)
                              (setf cleaned t)))
                (error (condition) condition))))
         (assert cleaned)
         (assert (not (probe-file owned)))
         (assert (equal saved (isolation-environment))))))
    (run-case
     "unset and empty are restored distinctly"
     (lambda ()
       (let ((saved (isolation-environment)))
         (unwind-protect
              (progn
                (sb-posix:unsetenv "TMPDIR")
                (sb-posix:setenv "HOME" "" 1)
                (call-with-isolated-e2e-environment #'assert-isolated-environment)
                (assert (null (sb-ext:posix-getenv "TMPDIR")))
                (assert (equal "" (sb-ext:posix-getenv "HOME"))))
           (dolist (entry saved)
             (if (cdr entry)
                 (sb-posix:setenv (car entry) (cdr entry) 1)
                 (sb-posix:unsetenv (car entry))))))))
    (run-case
     "cleanup error is not green and retains owned root"
     (lambda ()
       (let ((saved (isolation-environment)) (owned nil)
             (sentinel (make-condition 'simple-error :format-control "cleanup sentinel")))
         (unwind-protect
              (progn
                (assert
                 (eq sentinel
                     (handler-case
                         (call-with-isolated-e2e-environment
                          (lambda (root) (setf owned root) :success)
                          :cleanup (lambda (root)
                                     (assert-isolated-environment root)
                                     (error sentinel)))
                       (error (condition) condition))))
                (assert (probe-file owned))
                (assert (equal saved (isolation-environment))))
           (when owned
             (uiop:delete-directory-tree owned :validate t)))))))
  (format t "~&[isolation] ~D selected, ~D passed, ~D failed~%"
          (+ passed failed) passed failed)
  (sb-ext:exit :code (if (and (= passed 4) (zerop failed)) 0 1)))

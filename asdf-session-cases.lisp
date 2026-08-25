(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(load (truename "nerimux.asd"))

(defun run-case (label thunk)
  (format t "BEFORE ~A~%" label)
  (finish-output)
  (handler-case
      (progn
        (format t "RESULT ~A ~S~%" label (funcall thunk))
        (finish-output))
    (error (condition)
      (format t "ERROR ~A ~A~%" label condition)
      (finish-output))))

(format t "BEFORE-LET~%")
(finish-output)
(let* ((system (asdf/system-registry:registered-system "nerimux"))
       (ignore (progn (format t "AFTER-SYSTEM~%") (finish-output) nil))
       (operation (asdf/operation:make-operation
                   'asdf/find-system:define-op))
       (ignore-2 (progn (format t "AFTER-OPERATION~%") (finish-output) nil))
       (dummy (make-instance 'asdf/system:system :name "dummy")))
  (declare (ignore ignore ignore-2))
  (format t "AFTER-DUMMY~%")
  (finish-output)
  (run-case "registered-outside"
            (lambda () (asdf/action:component-depends-on operation system)))
  (run-case "dummy-outside"
            (lambda () (asdf/action:component-depends-on operation dummy)))
  (let ((asdf/session:*asdf-session* nil))
    (run-case "registered-nil-session"
              (lambda () (asdf/action:component-depends-on operation system)))
    (run-case "dummy-nil-session"
              (lambda () (asdf/action:component-depends-on operation dummy))))
  (let ((session (make-instance 'asdf/session:session)))
    (let ((asdf/session:*asdf-session* session))
      (run-case "registered-default-session"
                (lambda () (asdf/action:component-depends-on operation system)))
      (run-case "dummy-default-session"
                (lambda () (asdf/action:component-depends-on operation dummy)))))
  (let ((session (make-instance 'asdf/session:session
                                :session-cache (make-hash-table :test 'eq))))
    (let ((asdf/session:*asdf-session* session))
      (run-case "registered-eq-session"
                (lambda () (asdf/action:component-depends-on operation system)))
      (run-case "dummy-eq-session"
                (lambda () (asdf/action:component-depends-on operation dummy)))))
  (format t "DONE~%")
  (finish-output))

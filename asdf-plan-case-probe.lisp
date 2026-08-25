(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(load (truename "nerimux.asd"))
(eval `(trace asdf/session:consult-asdf-cache))
(eval `(trace asdf/action:component-depends-on))
(let ((system (asdf/system-registry:registered-system "nerimux")))
  (format t "SYSTEM=~S DEF-DEPS=~S~%" system
          (asdf/system:definition-dependency-list system))
  (labels ((run-case (label maker stamp-p)
             (format t "CASE-BEGIN ~A SESSION=~S~%" label asdf/session:*asdf-session*)
             (finish-output)
             (asdf/session:call-with-asdf-session
             (lambda ()
                (format t "CASE-SESSION ~A SESSION=~S~%" label asdf/session:*asdf-session*)
                (format t "CONSULT-BEGIN ~A~%" label)
                (format t "CONSULT ~A ~S~%" label
                        (asdf/session:consult-asdf-cache :probe (lambda () :ok)))
                (format t "BEFORE-MAKE ~A~%" label)
                (let* ((operation (asdf/operation:make-operation 'asdf/find-system:define-op)))
                  (let ((plan (funcall maker)))
                    (format t "AFTER-MAKE ~A~%" label)
                    (format t "CASE-PLAN ~A FORCE=~S~%" label
                            (and (typep plan 'asdf/plan:plan-traversal)
                                 (asdf/session:forcing plan)))
                  (finish-output)
                  (let ((generic (symbol-function 'asdf/action:component-depends-on)))
                    (format t "CASE-METHODS ~A ~S~%" label
                            (mapcar (lambda (method)
                                      (mapcar #'class-name
                                              (sb-mop:method-specializers method)))
                                    (sb-mop:generic-function-methods generic)))
                    (finish-output)
                    (multiple-value-bind (methods definitive-p)
                        (sb-mop:compute-applicable-methods-using-classes
                         generic (list (class-of operation) (class-of system)))
                      (format t "CASE-APPLICABLE ~A ~S ~S~%" label
                              (mapcar (lambda (method)
                                        (mapcar #'class-name
                                                (sb-mop:method-specializers method)))
                                      methods)
                              definitive-p)
                      (finish-output)))
                  (format t "CASE-DEPS-BEGIN ~A~%" label)
                  (format t "CASE-DEPS ~A ~S~%" label
                          (asdf/action:component-depends-on operation system))
                  (finish-output)
                    (when stamp-p
                      (format t "CASE-STAMP-BEGIN ~A~%" label)
                      (multiple-value-bind (stamp done-p)
                          (asdf/plan:compute-action-stamp plan operation system)
                        (format t "CASE-STAMP ~A ~S ~S~%" label stamp done-p)))))))))
    (run-case "BASE" (lambda () (make-instance 'asdf/plan:plan)) nil)
    (run-case "SEQUENTIAL-NIL" (lambda ()
                                  (make-instance 'asdf/plan:sequential-plan
                                                 :forcing nil)) t)
    (run-case "SEQUENTIAL" (lambda ()
                              (make-instance 'asdf/plan:sequential-plan)) t)))

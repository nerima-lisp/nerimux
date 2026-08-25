(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test #'equal))

(defparameter *end* (gensym "END"))

(with-open-file (stream (truename "asdf-metadata-module-probe.asd"))
  (let ((*package* (find-package :asdf-user))
        (forms nil))
    (loop for form = (read stream nil *end*)
          until (eq form *end*)
          do (push form forms))
    (dolist (form (nreverse forms))
      (format t "BEFORE-FORM ~S~%" (and (consp form) (car form)))
      (finish-output)
      (let ((*load-truename* (truename "asdf-metadata-module-probe.asd"))
            (*load-pathname* (truename "asdf-metadata-module-probe.asd")))
        (eval form))
      (format t "AFTER-FORM~%")
      (finish-output))))

(format t "BEFORE-DUMMY~%")
(finish-output)
(let ((dummy (make-instance 'asdf/system:system :name "dummy")))
  (format t "AFTER-DUMMY=~S~%" dummy)
  (finish-output))

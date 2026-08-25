(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(defparameter *end* (gensym "END"))

(with-open-file (stream (truename "nerimux.asd"))
  (let ((*package* (find-package :asdf-user)))
    (loop for index from 1
          for form = (read stream nil *end*)
          until (eq form *end*)
          do (format t "BEFORE-FORM ~D ~S PACKAGE=~A~%"
                     index (and (consp form) (car form)) (package-name *package*))
             (finish-output)
             (let ((*load-truename* (truename "nerimux.asd"))
                   (*load-pathname* (truename "nerimux.asd")))
               (eval form))
             (format t "AFTER-FORM ~D PACKAGE=~A SESSION-NIL=~S~%"
                     index (package-name *package*)
                     (null asdf/session:*asdf-session*))
             (finish-output)
             (when (= index 3)
               (format t "BEFORE-DUMMY~%")
               (finish-output)
               (format t "DUMMY=~S~%"
                       (make-instance 'asdf/system:system :name "dummy"))
               (format t "AFTER-DUMMY~%")
               (finish-output)))))

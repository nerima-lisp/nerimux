(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(defparameter *end* (gensym "END"))

(with-open-file (stream (truename "nerimux.asd"))
  (let ((*package* (find-package :asdf-user)))
    (loop for index from 1
          for form = (read stream nil *end*)
          until (eq form *end*)
          do (when (<= index 3)
               (format t "BEFORE-FORM ~D~%" index)
               (finish-output)
               (let ((*load-truename* (truename "nerimux.asd"))
                     (*load-pathname* (truename "nerimux.asd")))
                 (eval form))
               (format t "AFTER-FORM ~D~%" index)
               (finish-output))
             (when (= index 3)
               (return)))))

(let* ((tree (symbol-value (find-symbol "*NERIMUX-TEST-COMPONENTS*" :cl-user)))
       (root (first tree))
       (children (getf (cddr root) :components))
       (prefix-string (or (uiop:getenv "PROBE_PREFIX") "0"))
       (prefix (parse-integer prefix-string))
       (selected (if (zerop prefix) nil (subseq children 0 prefix)))
       (components (if (zerop prefix)
                       nil
                       (list (list :module "t"
                                   :serial t
                                   :components selected)))))
  (format t "TREE-LENGTH=~D PREFIX=~D~%" (length children) prefix)
  (finish-output)
  (format t "BEFORE-PROBE~%")
  (finish-output)
  (eval `(asdf:defsystem "nerimux/test-probe"
           :version "0.3.0"
           :components ,components))
  (format t "AFTER-PROBE~%")
  (finish-output)
  (format t "BEFORE-DUMMY~%")
  (finish-output)
  (format t "DUMMY=~S~%"
          (make-instance 'asdf/system:system :name "dummy"))
  (format t "AFTER-DUMMY~%")
  (finish-output))

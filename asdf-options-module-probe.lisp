(require :asdf)
(setf asdf/source-registry:*source-registry*
      (make-hash-table :test #'equal))

(format t "BEFORE-LOAD~%")
(finish-output)
(load (truename "asdf-options-module-probe.asd"))
(format t "AFTER-LOAD~%")
(finish-output)
(format t "BEFORE-DUMMY~%")
(finish-output)
(let ((dummy (make-instance 'asdf/system:system :name "dummy")))
  (format t "AFTER-DUMMY=~S~%" dummy)
  (finish-output))

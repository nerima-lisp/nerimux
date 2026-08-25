(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(format t "BEFORE-DIRECT-LOAD~%")
(finish-output)
(load (truename "nerimux.asd"))
(format t "AFTER-DIRECT-LOAD~%")
(finish-output)
(format t "SYSTEM=~S~%" (asdf:find-system "nerimux"))
(finish-output)

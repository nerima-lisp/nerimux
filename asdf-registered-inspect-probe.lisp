(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(load (truename "nerimux.asd"))
(let ((system (asdf:registered-system "nerimux")))
  (format t "SYSTEM=~S~%" system)
  (format t "SOURCE=~S~%" (asdf:system-source-file system))
  (format t "CHILDREN=~D~%" (length (asdf:component-children system)))
  (format t "DEF-DEPS=~S~%"
          (funcall (symbol-function (find-symbol "DEFINITION-DEPENDENCY-LIST" :asdf/system)) system))
  (format t "DEF-TIME=~S~%"
          (funcall (symbol-function (find-symbol "COMPONENT-OPERATION-TIME" :asdf/action))
                   (asdf:make-operation 'asdf:define-op) system)))
(finish-output)

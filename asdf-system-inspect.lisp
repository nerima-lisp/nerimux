(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(let* ((system (asdf:find-system "asdf"))
       (component-loaded-p (find-symbol "COMPONENT-LOADED-P" :asdf)))
  (format t "SYSTEM=~S~%" system)
  (format t "TYPE=~S~%" (type-of system))
  (format t "SOURCE=~S~%" (asdf:system-source-file system))
  (format t "DESCRIPTION=~S~%" (asdf:system-description system))
  (format t "DEPENDS=~S~%" (asdf:system-depends-on system))
  (format t "CHILDREN-COUNT=~D~%" (length (asdf:component-children system)))
  (dolist (child (asdf:component-children system))
    (format t "CHILD=~S TYPE=~S SOURCE=~S~%"
            (asdf:component-name child)
            (type-of child)
            (ignore-errors (asdf:component-pathname child))))
  (when component-loaded-p
    (format t "LOADED=~S~%"
            (funcall (symbol-function component-loaded-p) system))))

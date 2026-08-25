(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(let* ((system (asdf:find-system "asdf"))
       (component-depends-on (find-symbol "COMPONENT-DEPENDS-ON" :asdf/action)))
  (format t "COMPONENT=~S~%" system)
  (dolist (operation-name '(asdf:load-op asdf:prepare-op asdf:compile-op))
    (let ((operation (asdf:make-operation operation-name)))
      (format t "OP=~S~%" operation)
      (format t "COMPONENT-DEPS=~S~%"
              (funcall (symbol-function component-depends-on) operation system))
      (format t "DIRECT-DEPS=~S~%"
              (asdf/plan:direct-dependencies operation system)))))

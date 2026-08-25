(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(let* ((system (asdf:find-system "asdf"))
       (compile-op (asdf:make-operation 'asdf:compile-op))
       (input-files (find-symbol "INPUT-FILES" :asdf/action))
       (output-files (find-symbol "OUTPUT-FILES" :asdf/action))
       (operation-done-p (find-symbol "OPERATION-DONE-P" :asdf/action))
       (component-operation-time (find-symbol "COMPONENT-OPERATION-TIME" :asdf/action))
       (builtin-system-p (find-symbol "BUILTIN-SYSTEM-P" :asdf/system)))
  (format t "BUILTIN=~S SOURCE=~S PATH=~S~%"
          (funcall (symbol-function builtin-system-p) system)
          (asdf:system-source-file system)
          (ignore-errors (asdf:component-pathname system)))
  (format t "BEFORE-INPUT~%")
  (finish-output)
  (format t "INPUT=~S~%"
          (funcall (symbol-function input-files) compile-op system))
  (finish-output)
  (format t "BEFORE-OUTPUT~%")
  (finish-output)
  (format t "OUTPUT=~S~%"
          (funcall (symbol-function output-files) compile-op system))
  (finish-output)
  (format t "BEFORE-DONE~%")
  (finish-output)
  (format t "DONE=~S~%"
          (funcall (symbol-function operation-done-p) compile-op system))
  (finish-output)
  (format t "BEFORE-TIME~%")
  (finish-output)
  (format t "TIME=~S~%"
          (multiple-value-list
           (funcall (symbol-function component-operation-time)
                    compile-op system)))
  (finish-output))

(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(load (truename "nerimux.asd"))

(defun debug-hash-test (left right)
  (format t "HASH-TEST ~S ~S~%" (type-of left) (type-of right))
  (finish-output)
  (equal left right))

(defun debug-hash-function (key)
  (declare (ignore key))
  0)

(sb-ext:define-hash-table-test debug-hash-test
  debug-hash-function)

(let ((system (asdf/system-registry:registered-system "nerimux")))
  (format t "BEFORE-SESSION~%")
  (finish-output)
  (let ((asdf/session:*asdf-session*
          (make-instance 'asdf/session:session
                         :session-cache (make-hash-table
                                         :test 'debug-hash-test))))
    
     (let* ((session asdf/session:*asdf-session*)
            (cache (asdf/session:session-cache session))
            (operation (asdf/operation:make-operation
                        'asdf/find-system:define-op))
            (key (list 'asdf/action:component-depends-on operation system)))
       (format t "SESSION=~S TEST=~S COUNT=~S~%"
               session
               (hash-table-test cache)
               (hash-table-count cache))
       (finish-output)
       (format t "GET-RAW=~S~%"
               (multiple-value-list (gethash :probe cache)))
       (finish-output)
       (format t "GET-KEY=~S~%"
               (multiple-value-list (gethash key cache)))
       (finish-output)
       (format t "SET-KEY~%")
       (setf (gethash key cache) (list :ok))
       (format t "SET-DONE~%")
       (finish-output)
       (let* ((consult-symbol 'asdf/session:consult-asdf-cache)
              (consult (symbol-function consult-symbol)))
         (setf (symbol-function consult-symbol)
               (lambda (consult-key &optional thunk)
                 (format t "BEFORE-CONSULT KEY-LENGTH=~S~%"
                         (and (listp consult-key) (length consult-key)))
                 (finish-output)
                 (let ((values (multiple-value-list
                                 (funcall consult consult-key thunk))))
                   (format t "AFTER-CONSULT~%")
                   (finish-output)
                   (values-list values)))))
       (format t "BEFORE-COMPONENT-DEPS~%")
       (finish-output)
       (format t "COMPONENT-DEPS=~S~%"
               (asdf/action:component-depends-on operation system))
       (finish-output))))

(in-package #:nerimux)

(defun %parse-client-integer (value)
  (and (stringp value)
       (handler-case (parse-integer value)
         (parse-error ()
           nil))))

(defun %client-option-value (args names)
  (loop for tail on args
        for arg = (first tail)
        when (stringp arg)
          do (dolist (name names)
               (when (string-equal arg name)
                 (return-from %client-option-value
                   (second tail)))
               (when
                   (and (> (length arg) (length name))
                        (string-equal name arg :end2 (length name))
                        (char= (char arg (length name)) #\=))
                 (return-from %client-option-value
                   (subseq arg (1+ (length name))))))))

(defun %client-boolean-option-p (args names)
  (some
   (lambda (arg)
     (and (stringp arg)
          (some
           (lambda (name)
             (string-equal arg name))
           names)))
   args))

(defun %parse-client-key-code (value)
  (cond
    ((integerp value) value)
    ((stringp value)
     (let ((text (string-downcase value)))
       (cond
         ((member text '("c-q" "control-q" "control q") :test #'string=) #x11)
         ((member text '("c-b" "control-b" "control b") :test #'string=) #x02)
         ((= (length text) 1) (char-code (char text 0)))
         ((handler-case (parse-integer text)
            (parse-error ()
              nil)))
         (t nil))))
    (t nil)))

(defun %client-positional-branch (args)
  (let ((skip-next nil))
    (dolist (arg args)
      (cond
        (skip-next
         (setf skip-next nil))
        ((and (stringp arg)
              (member arg
                      '("--branch" "-b" "branch" "--path" "path")
                      :test
                      #'string-equal))
         (setf skip-next t))
        ((and (stringp arg)
              (plusp (length arg))
              (char/= (char arg 0) #\-)
              (not (member arg '("confirm" "force") :test #'string-equal)))
         (return-from %client-positional-branch
           arg))))))

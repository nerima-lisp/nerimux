(in-package #:nerimux/test)

(defmacro with-stubbed-locked-fdefinitions (bindings &body body)
  (let ((originals
         (loop for (name replacement) in bindings
               collect (list (gensym "ORIGINAL-") `(fdefinition ',name)))))
    `(sb-ext:without-package-locks
      (let ,originals
        (unwind-protect
            (progn
              ,@(loop for (name replacement) in bindings
                      for (original-variable original) in originals
                      collect `(setf (fdefinition ',name) ,replacement))
              ,@body)
          (progn
            ,@(loop for (name replacement) in bindings
                    for (original-variable original) in originals
                    collect `(setf (fdefinition ',name) ,original-variable))))))))

(defmacro with-stubbed-exit (code-var &body body)
  "Capture SB-EXT:EXIT's CODE and unwind BODY through a local catch."
  (let ((tag (gensym "EXIT-TAG"))
        (original (gensym "ORIGINAL-EXIT")))
    `(sb-ext:without-package-locks
       (let ((,original (fdefinition 'sb-ext:exit)))
         (setf (fdefinition 'sb-ext:exit)
               (lambda (&rest args &key (code 0) &allow-other-keys)
                 (declare (ignore args))
                 (setf ,code-var code)
                 (throw ',tag nil)))
         (unwind-protect
             (catch ',tag ,@body)
           (setf (fdefinition 'sb-ext:exit) ,original))))))

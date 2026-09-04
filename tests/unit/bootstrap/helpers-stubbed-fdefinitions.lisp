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

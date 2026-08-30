(in-package #:nerimux/test)

;;;; Process environment and fdefinition-swap fixtures.

(defmacro with-stubbed-fdefinition ((&rest bindings) &body body)
  "Replace each function cell in BINDINGS with its STUB-FORM for BODY.
   Every original definition is restored even if BODY signals."
  (let ((saved (loop for (symbol) in bindings
                     collect (list symbol (gensym (format nil "ORIG-~A" symbol))))))
    `(let ,(loop for (symbol orig-var) in saved
                collect `(,orig-var (fdefinition ',symbol)))
       (unwind-protect
            (progn
              ,@(loop for (symbol stub-form) in bindings
                     collect `(setf (fdefinition ',symbol) ,stub-form))
              ,@body)
         ,@(loop for (symbol orig-var) in saved
                collect `(setf (fdefinition ',symbol) ,orig-var))))))

(in-package #:nerimux/test/net)

;;;; Function-cell swap fixture.
;;;;
;;;; Copied into each unit that needs it rather than shared. nerimux-net depends
;;;; on no other unit, so there is no unit below both it and nerimux-pty that
;;;; could host the definition, and giving either test system an edge its own
;;;; unit does not have would defeat the point of the split. The same trade is
;;;; already recorded in tests/pty/helpers.lisp, which duplicates its fixtures
;;;; for the same reason. The macro touches no nerimux code.

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

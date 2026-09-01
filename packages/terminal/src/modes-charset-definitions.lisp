(in-package #:nerimux/terminal/actions)

;;;; Compile-time charset slot fact table.
(defmacro define-charset-slot-rules (&rest specs)
  "Build %CHARSET-SLOT-REF and %CHARSET-SLOT-SET from a declarative two-column
   table mapping G designator keywords to screen accessor names.
   Each SPEC is (:gN accessor-name)."
  `(progn
     (defun %charset-slot-ref (screen g)
       "Return the charset designated to G (:g0 or :g1) on SCREEN."
       (ecase g
         ,@(mapcar
            (lambda (s)
              `(,(car s) (,(cadr s) screen)))
            specs)))
     (defun %charset-slot-set (screen g charset)
       "Set the charset designated to G (:g0 or :g1) on SCREEN to CHARSET."
       (ecase g
         ,@(mapcar
            (lambda (s)
              `(,(car s)
                (setf (,(cadr s) screen) charset)))
            specs)))))

(define-charset-slot-rules (:g0 screen-g0-charset)
                           (:g1 screen-g1-charset)
                           (:g2 screen-g2-charset)
                           (:g3 screen-g3-charset))

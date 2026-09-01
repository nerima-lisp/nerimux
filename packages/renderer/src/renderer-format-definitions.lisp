(in-package #:nerimux/renderer)

;;;; Compile-time fact-table constructors for ANSI renderer helpers.
(defmacro define-colour-emitters (&rest specs)
  "Build %EMIT-FG and %EMIT-BG from a declarative spec table.
   Each SPEC is (name label std-base bright-base palette-prefix tc-prefix default-val).
   bright-base is std-base + 60 (i.e. 30+60=90 for fg, 40+60=100 for bg), offset
   by -8 so that (+ bright-base palette-index) yields the target SGR code directly
   for indices 8-15:  82+8=90, 82+15=97 for fg; 92+8=100, 92+15=107 for bg."
  `(progn
     ,@(mapcar
        (lambda (spec)
          (destructuring-bind (name label
                                    std-base
                                    bright-base
                                    palette-prefix
                                    tc-prefix
                                    default-val) spec
            `(defun ,name (stream n)
               ,(format nil
                        "Emit the ANSI SGR ~A colour code for value N to STREAM.~%~
                   N < 0: emit nothing (out-of-range / no-colour sentinel for tests).~%~
                   0-7:   standard colours   → ;~D-~D~%~
                   8-15:  bright colours     → ;~D-~D~%~
                   16-255: 256-colour palette → ;~A;N~%~
                   bit 24 set (#x1000000+): true-color → ;~A;R;G;B"
                        label
                        std-base
                        (+ std-base 7)
                        bright-base
                        (+ bright-base 7)
                        palette-prefix
                        tc-prefix)
               (when (>= n 0)
                 (let ((n (%maybe-downsample-color n)))
                   (cond
                     ((logbitp 24 n)
                      (let* ((rgb (logand n #xFFFFFF))
                             (r (ash rgb -16))
                             (g (logand (ash rgb -8) #xFF))
                             (b (logand rgb #xFF)))
                        (format stream ";~A;~D;~D;~D" ,tc-prefix r g b)))
                     ((<= 0 n 7) (format stream ";~D" (+ ,std-base n)))
                     ((<= 8 n 15) (format stream ";~D" (+ ,bright-base n)))
                     ((<= 16 n 255) (format stream ";~A;~D" ,palette-prefix n))
                     (t (format stream ";~D" ,default-val))))))))
        specs)))

(defmacro define-cell-attr-renderer (&rest bit-rules)
  "Build RENDER-CELL-ATTRS from a declarative table of (bit-index sgr-code) entries.
   Attribute bits are checked in order and the corresponding SGR code is emitted.
   The generated function also accepts ATTRS2 (extended attributes: double-underline
   and overline) and UL-COLOR (underline colour, SGR 58); both default to 0."
  `(defun render-cell-attrs (stream fg
                                    bg
                                    attrs
                                    &optional
                                    (attrs2 0)
                                    (ul-color 0))
     "Emit an SGR escape sequence resetting then applying FG, BG, ATTRS, ATTRS2 extended
      attributes (double-underline SGR 21, overline SGR 53), and UL-COLOR underline colour."
     (declare (type (unsigned-byte 8) attrs attrs2)
              (type (unsigned-byte 25) ul-color))
     (format stream "~C[0" +esc+)
     ,@(mapcar
        (lambda (rule)
          `(when (logbitp ,(first rule) attrs)
             (write-string ,(format nil ";~D" (second rule)) stream)))
        bit-rules)
     (when (logbitp 0 attrs2)
       (write-string ";21" stream))
     (when (logbitp 1 attrs2)
       (write-string ";53" stream))
     (%emit-fg stream fg)
     (%emit-bg stream bg)
     (%emit-ul-color stream ul-color)
     (write-char #\m stream)))

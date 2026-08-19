(in-package #:nerimux/terminal/actions)

;;;; Terminal modes — G0..G3 charset designation and invocation (ESC ( / ESC ) / SO / SI).

;;; ── Charset selection ────────────────────────────────────────────────────────
;;;
;;; G0 and G1 designation share the same two-way (:g0/:g1) slot dispatch.
;;; define-charset-slot-rules builds both the read and write helpers from one
;;; declarative table, consistent with the define-dec-pm-rules style.
;;;
;;; Prolog-like facts:
;;;   charset_slot(g0, Screen) :- screen-g0-charset(Screen).
;;;   charset_slot(g1, Screen) :- screen-g1-charset(Screen).

(defmacro define-charset-slot-rules (&rest specs)
  "Build %CHARSET-SLOT-REF and %CHARSET-SLOT-SET from a declarative two-column
   table mapping G designator keywords to screen accessor names.
   Each SPEC is (:gN accessor-name)."
  `(progn
     (defun %charset-slot-ref (screen g)
       "Return the charset designated to G (:g0 or :g1) on SCREEN."
       (ecase g
         ,@(mapcar (lambda (s) `(,(car s) (,(cadr s) screen))) specs)))
     (defun %charset-slot-set (screen g charset)
       "Set the charset designated to G (:g0 or :g1) on SCREEN to CHARSET."
       (ecase g
         ,@(mapcar (lambda (s) `(,(car s) (setf (,(cadr s) screen) charset)))
                   specs)))))

(define-charset-slot-rules
  (:g0 screen-g0-charset)
  (:g1 screen-g1-charset)
  (:g2 screen-g2-charset)
  (:g3 screen-g3-charset))

(defun screen-invoked-charset (screen g)
  "Return the charset currently designated to G (:g0 or :g1) on SCREEN."
  (%charset-slot-ref screen g))

(defun designate-charset (screen g charset)
  "Designate G (:g0 or :g1) of SCREEN to CHARSET — the effect of ESC ( X (G0)
   or ESC ) X (G1).  Updates the effective charset ONLY when G is the currently
   invoked set, so ESC ) 0 designates G1 without activating line-drawing until a
   SO (0x0E) locking shift selects G1."
  (%charset-slot-set screen g charset)
  (when (eq (screen-active-g screen) g)
    (setf (screen-charset screen) charset)))

(defun invoke-charset (screen g)
  "Invoke G (:g0 or :g1) as the active charset: SO (0x0E) invokes G1, SI (0x0F)
   invokes G0.  Sets the effective charset to G's current designation."
  (setf (screen-active-g screen) g
        (screen-charset screen) (screen-invoked-charset screen g)))

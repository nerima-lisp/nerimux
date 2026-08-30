(in-package #:nerimux/terminal/actions)

;;;; Terminal modes — G0..G3 charset designation and invocation (ESC ( / ESC ) / SO / SI).

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

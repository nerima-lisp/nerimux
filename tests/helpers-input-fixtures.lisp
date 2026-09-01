(in-package #:nerimux/test)

;;;; Session-registry and scrollback fixtures.
;;;; (Prompt/overlay fixtures were removed with the overlay/prompt subsystem
;;;; in R1; the format-context fixture was removed with domain/format in R2.
;;;; See git history.)
(defmacro with-empty-registry (&body body)
  "Bind *server-sessions* to NIL for the duration of BODY.
   Thin wrapper over `with-registered-sessions` for the empty-registry case."
  `(with-registered-sessions () ,@body))

(defun seed-scrollback (screen n)
  "Give SCREEN N dummy scrollback rows so copy-mode-scroll has room to move."
  (setf (nerimux/terminal/types::screen-scrollback screen) (loop repeat n
                                                                 collect (vector))))

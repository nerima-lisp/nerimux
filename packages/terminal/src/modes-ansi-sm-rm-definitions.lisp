(in-package #:nerimux/terminal/actions)

;;;; Terminal modes — ANSI (non-private) Set/Reset Mode, CSI Ps h / CSI Ps l.
;;;;
;;;; The macro and its declarative rule table are compile-time definitions.  The
;;;; generated actions are covered through the parser and terminal actions APIs.
(defmacro define-ansi-mode-rules (&rest specs)
  "Generate SET-ANSI-MODE and RESET-ANSI-MODE from a symmetric declarative table.
   Each SPEC is (param-number slot-accessor).
   Set writes T to the slot; Reset writes NIL."
  `(progn
     (defun set-ansi-mode (screen params)
       "ANSI Set Mode (CSI Ps h).  IRM (mode 4) turns on insert mode (printed chars
   shift the rest of the line right); LNM (mode 20) turns on newline mode (LF also
   carriage-returns)."
       (dolist (param params)
         (case param
           ,@(mapcar
              (lambda (s)
                `(,(car s)
                  (setf (,(cadr s) screen) t)))
              specs))))
     (defun reset-ansi-mode (screen params)
       "ANSI Reset Mode (CSI Ps l).  IRM (mode 4) turns off insert mode (replace/
   overwrite); LNM (mode 20) turns off newline mode (LF is a bare line feed)."
       (dolist (param params)
         (case param
           ,@(mapcar
              (lambda (s)
                `(,(car s)
                  (setf (,(cadr s) screen) nil)))
              specs))))))

(define-ansi-mode-rules (4 screen-insert-mode) (20 screen-newline-mode))

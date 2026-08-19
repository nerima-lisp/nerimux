(in-package #:nerimux/terminal/actions)

;;;; Terminal modes — ANSI (non-private) Set/Reset Mode, CSI Ps h / CSI Ps l.

;;; ── ANSI (non-private) Set/Reset Mode — CSI Ps h / CSI Ps l ─────────────────
;;;
;;; The non-private SM/RM modes (no `?` prefix).  IRM (mode 4, insert/replace) is
;;; the one with a visible effect; the rest are accepted and ignored so a stray
;;; `CSI 20 h` etc. does not corrupt the display.  PARAMS is a list of mode ints
;;; (as parsed for dec-pm-set).
;;;
;;; define-ansi-mode-rules mirrors define-dec-pm-rules but generates SET-ANSI-MODE
;;; and RESET-ANSI-MODE from one symmetric declarative table.  Each SPEC is
;;; (param-number slot-accessor) where slot-accessor names the boolean screen slot
;;; that the mode maps to.  Set → T, Reset → NIL.
;;;
;;; Prolog-like facts:
;;;   ansi_mode(4,  screen-insert-mode).
;;;   ansi_mode(20, screen-newline-mode).

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
           ,@(mapcar (lambda (s) `(,(car s) (setf (,(cadr s) screen) t))) specs))))
     (defun reset-ansi-mode (screen params)
       "ANSI Reset Mode (CSI Ps l).  IRM (mode 4) turns off insert mode (replace/
   overwrite); LNM (mode 20) turns off newline mode (LF is a bare line feed)."
       (dolist (param params)
         (case param
           ,@(mapcar (lambda (s) `(,(car s) (setf (,(cadr s) screen) nil))) specs))))))

(define-ansi-mode-rules
  (4  screen-insert-mode)
  (20 screen-newline-mode))

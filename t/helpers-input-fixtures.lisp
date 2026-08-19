(in-package #:nerimux/test)

;;;; Prompt, overlay, input, and format-context fixtures.

(defmacro with-clean-prompt (&body body)
  "Dynamically bind *prompt* to NIL and nerimux::*dirty* to NIL so prompt
   state never leaks between tests and dirty flags start clean."
  `(let ((*prompt* nil) (nerimux::*dirty* nil)) ,@body))

(defmacro with-clean-overlay (&body body)
  "Dynamically bind the four overlay specials (*overlay*, *overlay-scroll-offset*,
   *overlay-shown-at*, *display-panes-active*) to their inactive defaults so
   overlay state never leaks between tests.  Mirrors with-clean-prompt for the
   sibling overlay/popup/menu test file."
  `(let ((*overlay* nil)
         (*overlay-scroll-offset* 0)
         (*overlay-shown-at* 0)
         (*display-panes-active* nil))
     ,@body))

(defmacro with-empty-registry (&body body)
  "Bind *server-sessions* to NIL for the duration of BODY.
   Thin wrapper over `with-registered-sessions` for the empty-registry case."
  `(with-registered-sessions () ,@body))

(defun seed-scrollback (screen n)
  "Give SCREEN N dummy scrollback rows so copy-mode-scroll has room to move."
  (setf (nerimux/terminal/types::screen-scrollback screen)
        (loop repeat n collect (vector))))

;;; The 4-line let* that builds sess/win/pane/ctx from make-fake-session appears
;;; across format tests.  This macro encodes the standard extraction chain once.

(defmacro with-format-context ((sess-var win-var pane-var ctx-var)
                               (&key (nwindows 1) (npanes 1))
                               &body body)
  "Bind SESS-VAR/WIN-VAR/PANE-VAR/CTX-VAR to the first window, first pane, and
   format context of a fresh fake session with NWINDOWS windows and NPANES panes.
   Eliminates the recurring 4-line let* fixture in format-tests.lisp."
  `(let* ((,sess-var (make-fake-session :nwindows ,nwindows :npanes ,npanes))
          (,win-var  (first (nerimux/model:session-windows ,sess-var)))
          (,pane-var (first (nerimux/model:window-panes ,win-var)))
          (,ctx-var  (nerimux/format:format-context-from-session
                      ,sess-var ,win-var ,pane-var)))
     ,@body))

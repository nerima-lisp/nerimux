(in-package #:nerimux/test)

;;;; *prompt-history* fixture helpers -- runtime-history.lisp stores it as a
;;;; history-kit:history, not a plain list; these keep the many callers below
;;;; from repeating the same history-kit accessor chain.

(defun %prompt-history-texts ()
  "nerimux::*prompt-history*'s entries as a list of strings, newest first."
  (history-kit:history-entry-texts
   (history-kit:history-entries nerimux::*prompt-history*)))

(defun %prompt-history-of (&rest oldest-first-entries)
  "A fresh history-kit:history store seeded with ENTRIES, oldest first — the
   last entry given ends up newest, matching *prompt-history*'s add order."
  (let ((history (history-kit:make-history)))
    (dolist (entry oldest-first-entries history)
      (history-kit:history-add history entry))))

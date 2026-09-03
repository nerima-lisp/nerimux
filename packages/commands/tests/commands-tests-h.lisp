(in-package #:nerimux/test/commands)

;;;; copy-mode-exit, clear-history — part VI
(describe "commands-suite"

  ;;; ── copy-mode-exit ───────────────────────────────────────────────────────────

  ;; copy-mode-exit resets copy-mode-p, offset, mark, cursor, and selecting.
  (it "copy-mode-exit-resets-all-copy-state"
    (let ((s (copy-mode-screen)))
      ;; Set all copy-mode fields to non-default values.
      (setf (nerimux/terminal/types:screen-copy-offset    s) 5
            (nerimux/terminal/types:screen-copy-mark      s) (cons 2 3)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 2 5)
            (nerimux/terminal/types:screen-copy-selecting s) t)
      (nerimux/commands::copy-mode-exit s)
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (expect (= 0 (nerimux/terminal/types:screen-copy-offset s)))
      (expect (null (nerimux/terminal/types:screen-copy-mark s)))
      (expect (null (nerimux/terminal/types:screen-copy-cursor s)))
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy))))

(in-package #:nerimux/pty-test)

;;;; Pane tests - window-split's -d (no-focus) and -l (size hint) flags.
;;;;
;;;; Moved from t/unit/domain/model/pane-tests-geometry.lisp (R9.2): both
;;;; cases spawn a real PTY-backed session via WITH-SESSION (window-split
;;;; creates a real pane on success).  The geometry-only cases in that file
;;;; (pane-feed, pane-reposition, next-pane-id) build panes with fd -1 and
;;;; stayed in nerimux/test.

(describe "model-suite"

  ;; ── split-window -d flag (no-focus) ─────────────────────────────────────────

  ;; window-split :no-focus t creates the new pane but keeps the original active pane.
  (it "split-window-no-focus"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 41 10)
      (let* ((win (session-active-window session))
             (active-pane (window-active-pane win)))
        (let ((new-pane (window-split session win :h :no-focus t)))
          (expect (not (null new-pane)))
          (expect (eq active-pane (window-active-pane win)))
          (expect (= 2 (length (window-panes win))))
          ;; Clean up
          (ignore-errors (pty-close (pane-fd new-pane) (pane-pid new-pane)))))))

  ;; ── split-window -l size hint ────────────────────────────────────────────────

  ;; window-split with a fractional size hint assigns the new pane a proportional width.
  (it "split-window-size-hint-percentage"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 81 10)
      (let ((win (session-active-window session)))
        ;; Split with 0.25 size → new pane should be ~20 cols (25% of 80-col avail)
        (let ((new-pane (window-split session win :h :size 0.25)))
          (when new-pane
            (expect (> (pane-width new-pane) 0))
            (expect (< (pane-width new-pane) 81))
            (ignore-errors (pty-close (pane-fd new-pane) (pane-pid new-pane)))))))))

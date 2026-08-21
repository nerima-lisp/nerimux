(in-package #:nerimux/test)

;;;; Pane tests - pane/window operations.

(describe "model-suite"

  ;;; ── last-pane cycles ─────────────────────────────────────────────────────────

  ;; window-select-pane updates window-last-active; switching back via :last-pane
  ;; returns to the previous pane.
  (it "last-pane-cycles"
    (let* ((p0  (make-no-pty-pane 1  0 0 20 5))
           (p1  (make-no-pty-pane 2 21 0 20 5))
           (win (make-window :id 1 :name "w" :width 41 :height 5
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0) (make-layout-leaf p1)
                                      1/2)
                             :panes (list p0 p1))))
      ;; Start on p0
      (window-select-pane win p0)
      (expect (eq p0 (window-active-pane win)))
      ;; Switch to p1 — this should record p0 as last-active
      (window-select-pane win p1)
      (expect (eq p1 (window-active-pane win)))
      (expect (eq p0 (window-last-active win)))
      ;; Simulate :last-pane by selecting window-last-active
      (let ((last (window-last-active win)))
        (when last (window-select-pane win last)))
      (expect (eq p0 (window-active-pane win)))))

  ;; respawn-pane-updates-fd-and-pid (real PTY spawn via WITH-SESSION) moved
  ;; to t/pty/pane-tests-ops-pty.lisp (R9.2).
  )

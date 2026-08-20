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

  ;;; ── respawn-pane resets fd/pid ───────────────────────────────────────────────

  ;; respawn-pane closes the old PTY and assigns a fresh fd/pid to the pane.
  ;; Uses pty-available-p to skip when PTY spawning is not available.
  (it "respawn-pane-updates-fd-and-pid"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 20 20)
      (let* ((pane (session-active-pane session))
             (old-pid (pane-pid pane)))
        (respawn-pane session pane)
        ;; The new pid must differ (a new child process was spawned).
        ;; The fd may or may not be the same number (OS fd recycling), but
        ;; it must be non-negative (a valid open fd).
        (expect (not (= old-pid (pane-pid pane))))
        (expect (>= (pane-fd pane) 0))))))

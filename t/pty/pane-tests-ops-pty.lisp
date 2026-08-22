(in-package #:nerimux/pty-test)

;;;; Pane tests - respawn-pane resets fd/pid (real PTY).
;;;;
;;;; Moved from t/unit/domain/model/pane-tests-ops.lisp (R9.2): the one case
;;;; there that spawns a real PTY, via WITH-SESSION and respawn-pane.  The
;;;; no-PTY last-pane-cycles case stayed in nerimux/test.

(describe "model-suite"

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

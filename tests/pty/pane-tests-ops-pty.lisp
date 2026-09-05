(in-package #:nerimux/pty-test)

(describe "model-suite"

  (it "respawn-pane-updates-fd-and-pid"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 20 20)
      (let* ((pane (session-active-pane session))
             (old-pid (pane-pid pane)))
        (respawn-pane session pane)
        (expect (not (= old-pid (pane-pid pane))))
        (expect (>= (pane-fd pane) 0))))))

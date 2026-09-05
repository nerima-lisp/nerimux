(in-package #:nerimux/pty-test)

(describe "model-suite"


  (it "initial-session"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (expect (= 1 (length (session-windows session))))
      (let* ((win   (session-active-window session))
             (panes (window-panes win)))
        (expect (= 1 (length panes)))
        (let ((pane (first panes)))
          (expect (= 80 (pane-width  pane)))
          (expect (= 23 (pane-height pane)))
          (expect (eq pane (window-active-pane win)))))))


  (it "session-new-window"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((first-win (session-active-window session)))
        (session-new-window session "2" 23 80)
        (expect (= 2 (length (session-windows session))))
        (let ((new-win (session-active-window session)))
          (expect (not (eq first-win new-win)))
          (expect (= 1 (length (window-panes new-win))))))))


  (it "session-select-window"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((first-win (session-active-window session)))
        (session-new-window session "2" 23 80)
        (expect (not (eq first-win (session-active-window session))))
        (session-select-window session first-win)
        (expect (eq first-win (session-active-window session))))))


  (it "window-index-starts-at-one"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        (expect (= 1 (window-id win))))))

  (it "session-new-window-uses-lowest-free-id"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((first-win (session-active-window session)))
        (expect (= 1 (window-id first-win)))
        (session-new-window session "b" 23 80 1)
        (let* ((wins      (session-windows session))
               (second-win (find 2 wins :key #'window-id)))
          (expect second-win :to-be-truthy)))))


  (it "create-initial-session-increments-id-counter"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (let ((before nerimux/session::*session-id-counter*))
      (with-session (sess1 24 80)
        (expect (= (1+ before) (session-id sess1)))
        (expect (= (1+ before) nerimux/session::*session-id-counter*)))))

  (it "create-initial-session-session-touch-called"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (let ((before (get-universal-time)))
      (with-session (sess 24 80)
        (expect (>= (session-last-active sess) before))))))

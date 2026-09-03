(in-package #:nerimux/pty-test)

(describe "model-suite"


  (it "window-select-pane"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let* ((win        (session-active-window session))
             (first-pane (window-active-pane win)))
        (window-split session win :h)
        (expect (= 2 (length (window-panes win))))
        (expect (not (eq first-pane (window-active-pane win))))
        (window-select-pane win first-pane)
        (expect (eq first-pane (window-active-pane win))))))

  )

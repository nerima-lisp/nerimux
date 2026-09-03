(in-package #:nerimux/pty-test)

(describe "model-suite"


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
          (ignore-errors (pty-close (pane-fd new-pane) (pane-pid new-pane)))))))


  (it "split-window-size-hint-percentage"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 81 10)
      (let ((win (session-active-window session)))
        (let ((new-pane (window-split session win :h :size 0.25)))
          (when new-pane
            (expect (> (pane-width new-pane) 0))
            (expect (< (pane-width new-pane) 81))
            (ignore-errors (pty-close (pane-fd new-pane) (pane-pid new-pane)))))))))

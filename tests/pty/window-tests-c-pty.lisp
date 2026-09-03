(in-package #:nerimux/pty-test)

(describe "model-suite"

  (it "window-split-sets-pane-window-back-pointer"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let* ((win   (session-active-window session))
             (p-new (window-split session win :h)))
        (expect (eq win (pane-window p-new)))))))

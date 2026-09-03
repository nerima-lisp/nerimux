(in-package #:nerimux/renderer)

(defun %render-overlay-layer (buffer active-pane terminal-rows terminal-cols)
  "Move BUFFER's cursor to ACTIVE-PANE's screen cursor position."
  (declare (ignore terminal-rows terminal-cols))
  (when active-pane
    (let ((screen (pane-screen active-pane)))
      (with-lock-held ((screen-lock screen))
                      (move-to buffer
                               (+ (pane-y active-pane) (screen-cursor-y screen))
                               (+ (pane-x active-pane) (screen-cursor-x screen)))))))

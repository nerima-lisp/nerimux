(in-package #:nerimux/renderer)

;;;; Overlay-layer cursor placement for the nerimux renderer.
;;;;
;;;; The prompt/popup/menu/message overlay stack and the mouse-tracking
;;;; escape-sequence emitter that used to live here are gone (workspace
;;;; contraction phase 3, R1.1/R1.6/R1.10): mouse is not forwarded to panes,
;;;; and the only overlay this build has is the active pane's own cursor.
;;;; CSI 1000/1006 are still accepted and ignored by the terminal parser
;;;; (domain/terminal) — that is emulator correctness, not UI, and is
;;;; unaffected by this file.

(defun %render-overlay-layer (buffer active-pane terminal-rows terminal-cols)
  "Move BUFFER's cursor to ACTIVE-PANE's screen cursor position."
  (declare (ignore terminal-rows terminal-cols))
  (when active-pane
    (let ((screen (pane-screen active-pane)))
      (with-lock-held ((screen-lock screen))
        (move-to buffer
                 (+ (pane-y active-pane) (screen-cursor-y screen))
                 (+ (pane-x active-pane) (screen-cursor-x screen)))))))

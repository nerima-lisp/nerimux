(in-package #:nerimux/test/renderer)

(describe "renderer-suite"



  (it "status-left-text-copy-mode-has-no-indicator"
    (let* ((sess   (make-fake-session :nwindows 1))
           (ap     (session-active-pane  sess))
           (screen (pane-screen ap)))
      (setf (screen-copy-mode-p   screen) t
            (screen-copy-offset   screen) 2)
      (let ((left (nerimux/renderer::%status-left-text ap)))
        (expect (null (search "COPY" left)))
        (expect (null (search "+2" left))))))


  (it "render-panes-borders-suppressed-when-zoomed"
    (let* ((l0  (tl-leaf 1 1 1))
           (l1  (tl-leaf 2 1 1))
           (win (tl-window (make-layout-split :h l0 l1) 24 81))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (session-select-window sess win)
      (setf (nerimux/window:window-zoom-p win) t)
      (let ((buf (make-string-output-stream)))
        (nerimux/renderer::%render-panes-and-borders
         buf sess win (nerimux/window:window-panes win) (nerimux/window:window-active win) 81)
        (let ((out (get-output-stream-string buf)))
          (expect (null (find #\│ out))))))))

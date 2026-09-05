(in-package #:nerimux/test/renderer)

(describe "renderer-suite"


  (it "render-session-always-shows-status-bar"
    (let* ((sess (make-renderer-test-session 20 5))
           (out  (render-session-to-string sess 6 20)))
      (expect out :to-contain-sgr nerimux/renderer::+sgr-default-status+)))


  (it "render-bel-table"
    (dolist (row '((t   "bell-pending T: BEL emitted and flag cleared")
                   (nil "bell-pending NIL: BEL absent")))
      (destructuring-bind (initial-pending desc) row
        (declare (ignore desc))
        (let* ((sess  (make-renderer-test-session 20 5))
               (ap    (session-active-pane sess))
               (sc    (pane-screen ap)))
          (setf (nerimux/terminal/types:screen-bell-pending sc) initial-pending)
          (let* ((out    (render-session-to-string sess 6 20))
                 (before (%bel-before-title-osc out)))
            (expect (if initial-pending
                        (find (code-char 7) before)
                        (null (find (code-char 7) before))))
            (when initial-pending
              (expect (nerimux/terminal/types:screen-bell-pending sc) :to-be-falsy))))))))

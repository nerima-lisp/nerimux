(in-package #:nerimux/pty-test)

(describe "model-suite"

  (it "window-split-full-obeys-axis-minimums"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (dolist (row '((:h 4 24 "full h-split needs at least 5 columns")
                     (:v 80 2 "full v-split needs at least 3 rows")))
        (destructuring-bind (direction width height desc) row
          (declare (ignore desc))
          (let* ((p0   (make-no-pty-pane 1 0 0 width height))
                 (leaf (make-layout-leaf p0))
                 (win  (make-window :id 1 :name "w" :width width :height height
                                    :panes (list p0)
                                    :tree leaf)))
            (window-select-pane win p0)
            (expect (null (window-split session win direction :full t)))
            (expect (eq leaf (window-tree win)))
            (expect (equal (list p0) (window-panes win)))
            (expect (eq p0 (window-active-pane win)))))))))

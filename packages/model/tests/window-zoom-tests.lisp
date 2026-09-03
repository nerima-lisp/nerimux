(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "window-zoom-toggle-zoom-in-fills-window"
    (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
           (p1  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :width 81 :height 24
                             :panes (list p0 p1)
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0)
                                      (make-layout-leaf p1)
                                      1/2))))
      (window-select-pane win p0)
      (nerimux/window:window-zoom-toggle win)
      (expect (nerimux/window:window-zoom-p win) :to-be-truthy)
      (expect (equal (list p0) (window-panes win)))
      (expect (= 81 (pane-width  p0)))
      (expect (= 24 (pane-height p0)))
      (expect (= 0  (pane-x p0)))
      (expect (= 0  (pane-y p0)))))

  (it "window-zoom-toggle-zoom-out-restores-layout"
    (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
           (p1  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :width 81 :height 24
                             :panes (list p0 p1)
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0)
                                      (make-layout-leaf p1)
                                      1/2))))
      (window-select-pane win p0)
      (let ((w0-before (pane-width p0))
            (w1-before (pane-width p1)))
        (nerimux/window:window-zoom-toggle win)
        (nerimux/window:window-zoom-toggle win)
        (expect (nerimux/window:window-zoom-p win) :to-be-falsy)
        (expect (= 2 (length (window-panes win))))
        (expect (= w0-before (pane-width p0)))
        (expect (= w1-before (pane-width p1))))))

  (it "window-zoom-toggle-single-pane-zooms-and-unzooms"
    (let* ((p0  (make-no-pty-pane 1 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p0)
                             :tree (make-layout-leaf p0))))
      (window-select-pane win p0)
      (nerimux/window:window-zoom-toggle win)
      (expect (nerimux/window:window-zoom-p win) :to-be-truthy)
      (expect (= 1 (length (window-panes win))))
      (expect (= 80 (pane-width  p0)))
      (expect (= 24 (pane-height p0)))
      (nerimux/window:window-zoom-toggle win)
      (expect (nerimux/window:window-zoom-p win) :to-be-falsy)
      (expect (= 1 (length (window-panes win))))))


  (it "window-lock-slot-accessible"
    (let ((win (make-window :id 1 :name "w")))
      (expect (window-lock win) :to-be-truthy))))

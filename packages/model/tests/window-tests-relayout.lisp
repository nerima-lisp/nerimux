(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "window-relayout-vertical-preserves-split-no-pty"
    (let* ((start-rows 24) (start-cols 80)
           (p0 (make-no-pty-pane 1 0 0 39 start-rows))
           (p1 (make-no-pty-pane 2 40 0 40 start-rows))
           (win (make-window :id 1 :name "w"
                             :width start-cols :height start-rows
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0)
                                      (make-layout-leaf p1))
                             :panes (list p0 p1) :active p1)))
      (let* ((new-rows 40) (new-cols 100))
        (window-relayout win new-rows new-cols)
        (expect (= new-cols (window-width  win)))
        (expect (= new-rows (window-height win)))
        (dolist (pair (list (list p0 "pane 1") (list p1 "pane 2")))
          (destructuring-bind (p lbl) pair
            (declare (ignore lbl))
            (expect (= new-rows (pane-height p)))
            (expect (plusp (pane-width p)))))
        (expect (= new-cols (+ (pane-width p0) 1 (pane-width p1))))
        (check-table (list (list (screen-width  (pane-screen p0)) (pane-width p0)  "pane 1 screen-width")
                           (list (screen-height (pane-screen p0)) (pane-height p0) "pane 1 screen-height")
                           (list (screen-width  (pane-screen p1)) (pane-width p1)  "pane 2 screen-width")
                           (list (screen-height (pane-screen p1)) (pane-height p1) "pane 2 screen-height"))
                     :test #'equal)
        (expect (= 1 (- (pane-x p1) (+ (pane-x p0) (pane-width p0))))))))


  (it "window-relayout-single-pane-tree-fullscreen"
    (let* ((pane (make-no-pty-pane 1 5 5 10 10))
           (win  (make-window :id 1 :name "w"
                              :width 10 :height 10
                              :tree (make-layout-leaf pane)
                              :panes (list pane) :active pane)))
      (window-relayout win 30 90)
      (check-table (list (list (pane-x      pane)              0  "pane x")
                         (list (pane-y      pane)              0  "pane y")
                         (list (pane-width  pane)              90 "pane width")
                         (list (pane-height pane)              30 "pane height")
                         (list (screen-width  (pane-screen pane)) 90 "screen width")
                         (list (screen-height (pane-screen pane)) 30 "screen height"))
                   :test #'equal)))

  (it "window-relayout-no-tree-is-noop-for-panes"
    (let* ((p0 (make-no-pty-pane 1 5 5 10 10))
           (p1 (make-no-pty-pane 2 7 7 12 12))
           (win (make-window :id 1 :name "w"
                             :width 10 :height 10
                             :panes (list p0 p1) :active p0)))
      (window-relayout win 30 90)
      (check-table (list (list (window-width  win) 90 "window width updated")
                         (list (window-height win) 30 "window height updated")
                         (list (pane-x      p0) 5  "p0 x unchanged: no tree")
                         (list (pane-y      p0) 5  "p0 y unchanged: no tree")
                         (list (pane-width  p0) 10 "p0 width unchanged: no tree")
                         (list (pane-height p0) 10 "p0 height unchanged: no tree")
                         (list (pane-x      p1) 7  "p1 x unchanged: no tree")
                         (list (pane-y      p1) 7  "p1 y unchanged: no tree")
                         (list (pane-width  p1) 12 "p1 width unchanged: no tree")
                         (list (pane-height p1) 12 "p1 height unchanged: no tree"))
                   :test #'equal)))


  (it "window-relayout-current-uses-stored-dimensions"
    (let* ((p0  (make-no-pty-pane 1 0 0 1 1))
           (win (make-window :id 1 :name "w" :width 90 :height 30
                             :tree (make-layout-leaf p0)
                             :panes (list p0) :active p0)))
      (window-relayout-current win)
      (check-table (list (list (window-width  win)              90 "window width unchanged")
                         (list (window-height win)              30 "window height unchanged")
                         (list (pane-width  p0)                 90 "pane width fills stored window width")
                         (list (pane-height p0)                 30 "pane height fills stored window height")
                         (list (screen-width  (pane-screen p0)) 90 "screen width matches stored window width")
                         (list (screen-height (pane-screen p0)) 30 "screen height matches stored window height")))))


  (it "ensure-window-fits-relayouts-on-size-change"
    (let* ((pane (make-no-pty-pane 1 0 0 80 24))
           (win  (make-window :id 1 :name "w"
                              :width 80 :height 24
                              :tree (make-layout-leaf pane)
                              :panes (list pane) :active pane)))
      (nerimux/window::ensure-window-fits win 30 100)
      (check-table (list (list (window-width  win)              100 "window width")
                         (list (window-height win)              30  "window height")
                         (list (pane-width  pane)               100 "pane width")
                         (list (pane-height pane)               30  "pane height")
                         (list (screen-width  (pane-screen pane)) 100 "screen width")
                         (list (screen-height (pane-screen pane)) 30  "screen height")))))

  (it "ensure-window-fits-noop-when-size-matches"
    (let* ((screen (make-screen 80 24))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 80 :height 24
                              :fd -1 :pid -1 :screen screen))
           (win    (make-window :id 1 :name "w"
                                :width 80 :height 24
                                :tree (make-layout-leaf pane)
                                :panes (list pane) :active pane)))
      (nerimux/window::ensure-window-fits win 24 80)
      (check-table (list (list (window-width  win)              80 "window width")
                         (list (window-height win)              24 "window height")
                         (list (pane-x      pane)              0  "pane x")
                         (list (pane-y      pane)              0  "pane y")
                         (list (pane-width  pane)              80 "pane width")
                         (list (pane-height pane)              24 "pane height")
                         (list (screen-width  (pane-screen pane)) 80 "screen width")
                         (list (screen-height (pane-screen pane)) 24 "screen height")))
      (expect (eq screen (pane-screen pane))))))

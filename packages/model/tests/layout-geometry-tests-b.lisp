(in-package #:nerimux/test/model)

(describe "layout-geometry-suite"


  (it "ranges-overlap-p-table"
    (dolist (row '((t   0  5 3  5 "[0,5) and [3,8) overlap at 3..4")
                   (t   0 10 5  3 "[0,10) and [5,8) overlap")
                   (t   5  5 4  2 "[5,10) and [4,6) share 5")
                   (nil 0  5 5  5 "[0,5) and [5,10) touch but do not overlap")
                   (nil 5  5 0  5 "[5,10) and [0,5) touch but do not overlap")
                   (nil 0  3 10 5 "[0,3) and [10,15) are disjoint")
                   (nil 10 5 0  3 "[10,15) and [0,3) are disjoint")))
      (destructuring-bind (expected s1 e1 s2 e2 desc) row
        (declare (ignore desc))
        (expect (eq expected (nerimux/window::%ranges-overlap-p s1 e1 s2 e2))))))


  (it "pane-center-x-returns-midpoint"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :x 10 :y 0 :width 20 :height 5
                           :screen (make-screen 20 5))))
      (expect (= 20 (nerimux/window::%pane-center-x pane)))))

  (it "pane-center-y-returns-midpoint"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :x 0 :y 4 :width 10 :height 8
                           :screen (make-screen 10 8))))
      (expect (= 8 (nerimux/window::%pane-center-y pane)))))


  (it "closest-to-center-picks-nearest"
    (with-center-test-panes ((pane 0 0 10 10 4)
                              (a    1 0  0 10 4)
                              (b    2 0  8 10 4))
      (expect (eq b (nerimux/window::%closest-to-center (list a b) pane
                                                    #'nerimux/window::%pane-center-y)))))

  (it "closest-to-center-tie-favors-first-candidate"
    (with-center-test-panes ((pane 0 0 10 10 4)
                              (a    1 0  8 10 4)
                              (b    2 0 12 10 4))
      (expect (eq a (nerimux/window::%closest-to-center (list a b) pane
                                                    #'nerimux/window::%pane-center-y)))))

  (it "closest-to-center-three-candidates-non-trivial"
    (with-center-test-panes ((pane       0 20 0 4 10)
                              (far-left  1  0 0 4 10)
                              (near-left 2 16 0 4 10)
                              (far-right 3 40 0 4 10))
      (expect (eq near-left
              (nerimux/window::%closest-to-center (list far-left near-left far-right)
                                                  pane #'nerimux/window::%pane-center-x)))))


  (it "layout-split-axis-extent-v-split"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :v l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 80 21)
      (expect (= 21 (nerimux/layout::layout-split-axis-extent tree :v)))
      (expect (= 80 (nerimux/layout::layout-split-axis-extent tree :h)))))


  (it "resize-find-split-nested-tree-climbs-to-ancestor"
    (let* ((left  (tl-leaf 1 1 1))
           (top   (tl-leaf 2 1 1))
           (bot   (tl-leaf 3 1 1))
           (inner (make-layout-split :v top bot))
           (outer (make-layout-split :h left inner)))
      (multiple-value-bind (split side)
          (nerimux/layout::resize-find-split outer top :h)
        (expect (eq outer split))
        (expect (eq :second side)))))


  (it "pane-at-position-out-of-bounds-returns-nil"
    (with-h-split-81-24 (p0 p1 win)
      (expect (null (nerimux/window:pane-at-position win 0 24)))
      (expect (null (nerimux/window:pane-at-position win 81 0)))))


  (it "orient-case-signals-on-unknown-orientation"
    (signals error
      (nerimux/layout::orient-case :diagonal :h :horiz :v :vert)))


  (it "split-child-geometry-v-odd-height-correct-division"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :x 0 :y 0 :width 40 :height 11
                           :screen (make-screen 40 11))))
      (multiple-value-bind (nx ny nw nh)
          (nerimux/layout::split-child-geometry pane :v)
        (expect (= 0  nx))
        (expect (= 6  ny))
        (expect (= 40 nw))
        (expect (= 5  nh)))))

  (it "split-child-geometry-h-odd-width-correct-division"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :x 0 :y 0 :width 11 :height 24
                           :screen (make-screen 11 24))))
      (multiple-value-bind (nx ny nw nh)
          (nerimux/layout::split-child-geometry pane :h)
        (expect (= 6  nx))
        (expect (= 0  ny))
        (expect (= 5  nw))
        (expect (= 24 nh)))))


  (it "pane-neighbor-three-panes-middle-pane-finds-both-neighbors"
    (let* ((p0  (make-pane :id 1 :fd -1 :pid -1 :x  0 :y 0 :width 20 :height 24
                            :screen (make-screen 20 24)))
           (p1  (make-pane :id 2 :fd -1 :pid -1 :x 21 :y 0 :width 20 :height 24
                            :screen (make-screen 20 24)))
           (p2  (make-pane :id 3 :fd -1 :pid -1 :x 42 :y 0 :width 20 :height 24
                            :screen (make-screen 20 24)))
           (win (make-window :id 1 :name "w" :width 62 :height 24
                             :panes (list p0 p1 p2)
                             :tree  (make-layout-split :h
                                       (make-layout-leaf p0)
                                       (make-layout-split :h
                                          (make-layout-leaf p1)
                                          (make-layout-leaf p2))))))
      (window-select-pane win p1)
      (expect (eq p0 (pane-neighbor win p1 :left)))
      (expect (eq p2 (pane-neighbor win p1 :right)))))


  (it "define-axis-rules-generates-correct-dispatch"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :width 30 :height 12
                           :screen (make-screen 30 12))))
      (expect (= 12 (nerimux/window::%orient-pane-extent pane :v)))
      (expect (= 30 (nerimux/window::%orient-pane-extent pane :h)))))

  (it "neighbor-filters-alist-has-all-four-directions"
    (let ((dirs (mapcar #'car nerimux/window::*neighbor-filters*)))
      (expect (member :right dirs))
      (expect (member :left  dirs))
      (expect (member :down  dirs))
      (expect (member :up    dirs))))

  (it "neighbor-center-fn-alist-has-all-four-directions"
    (let ((dirs (mapcar #'car nerimux/window::*neighbor-center-fn*)))
      (expect (member :right dirs))
      (expect (member :left  dirs))
      (expect (member :down  dirs))
      (expect (member :up    dirs))))


  (it "layout-min-extent-nested-v-h-split"
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (l2    (tl-leaf 3 1 1))
           (inner (make-layout-split :h l0 l1))
           (outer (make-layout-split :v inner l2)))
      (expect (= 3 (nerimux/layout::layout-min-extent outer :v)))
      (expect (= 5 (nerimux/layout::layout-min-extent outer :h))))))

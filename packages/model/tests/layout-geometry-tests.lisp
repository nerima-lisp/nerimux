(in-package #:nerimux/test/model)

(describe "layout-geometry-suite"


  (it "axis-floor-returns-correct-minimum"
    (expect (= nerimux/layout::+pane-min-height+ (nerimux/layout::%axis-floor :v)))
    (expect (= nerimux/layout::+pane-min-width+  (nerimux/layout::%axis-floor :h))))



  (it "layout-assign-single-leaf-fills-rect"
    (let* ((p    (make-pane :id 1 :fd -1 :pid -1 :width 1 :height 1
                            :screen (make-screen 1 1)))
           (leaf (make-layout-leaf p)))
      (nerimux/layout::layout-assign leaf 3 5 40 20)
      (check-table (list (list (pane-x p) 3 "pane-x")
                         (list (pane-y p) 5 "pane-y")
                         (list (pane-width p) 40 "pane-width")
                         (list (pane-height p) 20 "pane-height")))))

  (it "layout-assign-h-split-divides-width"
    (with-two-1x1-panes (p0 p1)
      (let ((tree (make-layout-split :h (make-layout-leaf p0) (make-layout-leaf p1) 1/2)))
        (nerimux/layout::layout-assign tree 0 0 81 24)
        (check-table (list (list (pane-x p0) 0 "p0 at column 0")
                           (list (pane-width p0) 40 "p0 width 40")
                           (list (pane-x p1) 41 "p1 starts one past separator")
                           (list (pane-width p1) 40 "p1 width 40")
                           (list (pane-height p0) 24 "p0 full height")
                           (list (pane-height p1) 24 "p1 full height"))))))


  (it "layout-split-axis-extent-h-split"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 81 24)
      (expect (= 81 (nerimux/layout::layout-split-axis-extent tree :h)))
      (expect (= 24 (nerimux/layout::layout-split-axis-extent tree :v)))))


  (it "resize-find-split-finds-nearest-ancestor"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (multiple-value-bind (split side)
          (nerimux/layout::resize-find-split tree l0 :h)
        (expect (eq tree split))
        (expect (eq :first side)))
      (multiple-value-bind (split side)
          (nerimux/layout::resize-find-split tree l1 :h)
        (expect (eq tree split))
        (expect (eq :second side)))))

  (it "resize-find-split-returns-nil-for-wrong-orientation"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (multiple-value-bind (split side)
          (nerimux/layout::resize-find-split tree l0 :v)
        (expect (null split))
        (expect (null side)))))


  (it "resize-direction-orientation-mapping"
    (dolist (c '((:left :h) (:right :h) (:up :v) (:down :v)))
      (destructuring-bind (dir expected) c
        (expect (eq expected (nerimux/layout::resize-direction-orientation dir))))))


  (it "pane-neighbor-h-split"
    (with-h-split-window (win p0 p1)
      (expect (eq p1 (pane-neighbor win p0 :right)))
      (window-select-pane win p1)
      (expect (eq p0 (pane-neighbor win p1 :left)))))

  (it "pane-neighbor-nil"
    (let* ((p0  (make-pane :id 1 :fd -1 :pid -1
                            :x 0 :y 0 :width 80 :height 24
                            :screen (make-screen 80 24)))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p0)
                             :tree (make-layout-leaf p0))))
      (window-select-pane win p0)
      (dolist (dir '(:right :left :up :down))
        (expect (null (pane-neighbor win p0 dir))))))

  (it "pane-neighbor-v-split"
    (with-v-split-window (win p0 p1)
      (expect (eq p1 (pane-neighbor win p0 :down)))
      (window-select-pane win p1)
      (expect (eq p0 (pane-neighbor win p1 :up)))))


  (it "pane-at-position-h-split-table"
    (with-h-split-81-24 (p0 p1 win)
      (dolist (entry (list (list  0  0 p0  "origin → p0")
                           (list 39 23 p0  "bottom-right of p0 → p0")
                           (list 40  0 nil "separator col 40 → NIL")
                           (list 41  0 p1  "start of p1 → p1")
                           (list 80 23 p1  "bottom-right of p1 → p1")))
        (destructuring-bind (col row expected desc) entry
          (declare (ignore desc))
          (expect (equal expected (nerimux/window:pane-at-position win col row)))))))

  (it "pane-at-position-single-pane"
    (let* ((p0  (make-pane :id 1 :fd -1 :pid -1
                            :x 0 :y 0 :width 80 :height 24
                            :screen (make-screen 80 24)))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p0)
                             :tree  (make-layout-leaf p0))))
      (dolist (entry (list (list  0  0 p0  "origin")
                           (list 79 23 p0  "max corner")
                           (list 80  0 nil "out-of-bounds col")))
        (destructuring-bind (col row expected desc) entry
          (declare (ignore desc))
          (expect (equal expected (nerimux/window:pane-at-position win col row)))))))


  (it "orient-case-table"
    (dolist (row '((:h :horizontal 40 ":h orientation selects :h branch")
                   (:v :vertical   20 ":v orientation selects :v branch")))
      (destructuring-bind (orient expected-kw expected-num desc) row
        (declare (ignore desc))
        (expect (eq expected-kw
                    (nerimux/layout::orient-case orient :h :horizontal :v :vertical)))
        (expect (= expected-num
                   (nerimux/layout::orient-case orient :h 40 :v 20))))))


  (it "split-child-geometry-vertical-split-dimensions"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1
                            :x 0 :y 0 :width 80 :height 21
                            :screen (make-screen 80 21))))
      (multiple-value-bind (nx ny nw nh)
          (nerimux/layout::split-child-geometry pane :v)
        (check-table (list (list nx 0 ":v split: new child x must equal parent x")
                           (list ny 11 ":v split: new child y must be pane-y + fh + 1")
                           (list nw 80 ":v split: new child width must equal parent width")
                           (list nh 10 ":v split: new child height must be avail - fh"))))))

  (it "split-child-geometry-horizontal-split-dimensions"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1
                            :x 0 :y 0 :width 81 :height 24
                            :screen (make-screen 81 24))))
      (multiple-value-bind (nx ny nw nh)
          (nerimux/layout::split-child-geometry pane :h)
        (check-table (list (list nx 41 ":h split: new child x must be pane-x + fw + 1")
                           (list ny 0 ":h split: new child y must equal parent y")
                           (list nw 40 ":h split: new child width must be avail - fw")
                           (list nh 24 ":h split: new child height must equal parent height"))))))


  (it "layout-min-extent-single-leaf-table"
    (let* ((p    (make-pane :id 1 :fd -1 :pid -1 :width 40 :height 15
                            :screen (make-screen 40 15)))
           (leaf (make-layout-leaf p)))
      (check-table (list (list (nerimux/layout::layout-min-extent leaf :v)
                               nerimux/layout::+pane-min-height+ "leaf :v extent")
                         (list (nerimux/layout::layout-min-extent leaf :h)
                               nerimux/layout::+pane-min-width+ "leaf :h extent")))))

  (it "layout-min-extent-h-split-same-axis"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (let ((expected (+ nerimux/layout::+pane-min-width+
                         1
                         nerimux/layout::+pane-min-width+)))
        (expect (= expected (nerimux/layout::layout-min-extent tree :h))))))

  (it "layout-min-extent-h-split-cross-axis"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (expect (= nerimux/layout::+pane-min-height+
                 (nerimux/layout::layout-min-extent tree :v)))))

  (it "layout-min-extent-nil-node"
    (expect (= 0 (nerimux/layout::layout-min-extent nil :h)))
    (expect (= 0 (nerimux/layout::layout-min-extent nil :v))))


  (it "layout-assign-v-split-divides-height"
    (with-two-1x1-panes (p0 p1)
      (let ((tree (make-layout-split :v (make-layout-leaf p0) (make-layout-leaf p1) 1/2)))
        (nerimux/layout::layout-assign tree 0 0 80 21)
        (expect (= 0  (pane-y p0)))
        (expect (= 10 (pane-height p0)))
        (expect (= 11 (pane-y p1)))
        (expect (= 10 (pane-height p1)))
        (expect (= 80 (pane-width p0)))
        (expect (= 80 (pane-width p1))))))


  (it "assign-split-extreme-ratio-clamping-table"
    (dolist (row '((1/100  "near-zero ratio: first child clamped to >= 1")
                   (99/100 "near-unity ratio: second child clamped to >= 1")))
      (destructuring-bind (ratio desc) row
        (declare (ignore desc))
        (with-two-1x1-panes (p0 p1)
          (let ((tree (make-layout-split :h (make-layout-leaf p0) (make-layout-leaf p1) ratio)))
            (nerimux/layout::layout-assign tree 0 0 80 24)
            (expect (>= (pane-width p0) 1))
            (expect (>= (pane-width p1) 1))
            (expect (= 79 (+ (pane-width p0) (pane-width p1)))))))))

  (it "assign-split-exact-half-ratio-distributes-evenly"
    (with-two-1x1-panes (p0 p1)
      (let ((tree (make-layout-split :h (make-layout-leaf p0) (make-layout-leaf p1) 1/2)))
        (nerimux/layout::layout-assign tree 0 0 81 24)
        (expect (= 40 (pane-width p0)))
        (expect (= 40 (pane-width p1))))))

  )

(in-package #:nerimux/test/model)

(describe "layout-tree-suite"


  (it "layout-leaves-collects-in-order"
    (let* ((l0 (tl-leaf 1 10 10))
           (l1 (tl-leaf 2 10 10))
           (l2 (tl-leaf 3 10 10))
           (tree (make-layout-split :h l0 (make-layout-split :v l1 l2))))
      (expect (equal (list (layout-leaf-pane l0)
                           (layout-leaf-pane l1)
                           (layout-leaf-pane l2))
                     (layout-leaves tree)))))

  (it "layout-find-parent-resolves-side"
    (let* ((l0 (tl-leaf 1 10 10))
           (l1 (tl-leaf 2 10 10))
           (split (make-layout-split :h l0 l1)))
      (multiple-value-bind (p w) (layout-find-parent split l1)
        (expect (eq split p))
        (expect (eq :second w)))))


  (it "relayout-h-split-divides-only-into-two"
    (let* ((tree (make-layout-split :h (tl-leaf 1 1 1) (tl-leaf 2 1 1)))
           (win  (tl-window tree 24 81)))
      (destructuring-bind (p0 p1) (window-panes win)
        (check-table (list (list (pane-x p0) 0 "p0 at column 0")
                           (list (pane-width p0) 40 "p0 width 40")
                           (list (pane-x p1) 41 "right pane sits one column past the separator")
                           (list (pane-width p1) 40 "p1 width 40")
                           (list (pane-height p0) 24 "full height on a left/right split")
                           (list (pane-height p1) 24 "p1 height 24")
                           (list (- (pane-x p1) (+ (pane-x p0) (pane-width p0))) 1
                                 "exactly one separator column between them"))))))

  (it "nested-mixed-layout-geometry"
    (let* ((top    (tl-leaf 1 1 1))
           (bl     (tl-leaf 2 1 1))
           (br     (tl-leaf 3 1 1))
           (tree   (make-layout-split :v top (make-layout-split :h bl br)))
           (win    (tl-window tree 25 80)))
      (destructuring-bind (ptop pbl pbr) (window-panes win)
        (check-table (list (list (pane-y ptop) 0 "top pane at row 0")
                           (list (pane-height ptop) 12 "top pane height 12")
                           (list (pane-width ptop) 80 "top spans full width")
                           (list (pane-y pbl) 13 "bottom-left starts at row 13")
                           (list (pane-y pbr) 13 "bottom-right starts at row 13")
                           (list (pane-height pbl) 12 "bottom-left height 12")
                           (list (pane-height pbr) 12 "bottom-right height 12")
                           (list (pane-x pbl) 0 "bottom-left at column 0")
                           (list (pane-width pbl) 40 "bottom-left width 40")
                           (list (pane-x pbr) 41 "bottom-right at column 41")
                           (list (pane-width pbr) 39 "bottom-right width 39")))
        (expect (<= (+ (pane-x pbl) (pane-width pbl)) (pane-x pbr))))))


  (it "resize-h-right-moves-border-and-reflows"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (win  (tl-window tree 24 81 :active (layout-leaf-pane l0))))
      (destructuring-bind (p0 p1) (window-panes win)
        (expect (= 40 (pane-width p0)))
        (expect (eq p0 (window-resize-active win :right 5)))
        (expect (= 45 (pane-width p0)))
        (expect (= 35 (pane-width p1)))
        (expect (= 46 (pane-x p1))))))

  (it "resize-v-down-moves-border"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :v l0 l1))
           (win  (tl-window tree 25 80 :active (layout-leaf-pane l0))))
      (destructuring-bind (p0 p1) (window-panes win)
        (expect (= 12 (pane-height p0)))
        (expect (eq p0 (window-resize-active win :down 3)))
        (expect (= 15 (pane-height p0)))
        (expect (= 9  (pane-height p1)))
        (expect (= 16 (pane-y p1))))))

  (it "resize-orthogonal-axis-finds-ancestor"
    (let* ((left  (tl-leaf 1 1 1))
           (rt    (tl-leaf 2 1 1))
           (rb    (tl-leaf 3 1 1))
           (tree  (make-layout-split :h left (make-layout-split :v rt rb)))
           (win   (tl-window tree 25 81 :active (layout-leaf-pane left))))
      (destructuring-bind (pl prt prb) (window-panes win)
        (let ((w-before (pane-width pl)))
          (expect (eq pl (window-resize-active win :right 4)))
          (expect (= (+ w-before 4) (pane-width pl)))
          (expect (= (pane-x prt) (pane-x prb)))
          (expect (< (pane-y prt) (pane-y prb)))))))

  (it "resize-no-neighbour-is-noop"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (win  (tl-window tree 24 81 :active (layout-leaf-pane l0))))
      (let ((w0 (pane-width (first (window-panes win)))))
        (expect (null (window-resize-active win :up 5)))
        (expect (= w0 (pane-width (first (window-panes win))))))))


  (it "split-too-small-aborts-without-forking"
    (let* ((pane (tl-pane 1 3 24))
           (win  (make-window :id 1 :name "w" :width 3 :height 24
                              :tree (make-layout-leaf pane)
                              :panes (list pane) :active pane)))
      (expect (null (window-split nil win :h)))
      (expect (= 1 (length (window-panes win)))))
    (let* ((pane (tl-pane 1 80 2))
           (win  (make-window :id 1 :name "w" :width 80 :height 2
                              :tree (make-layout-leaf pane)
                              :panes (list pane) :active pane)))
      (expect (null (window-split nil win :v)))
      (expect (= 1 (length (window-panes win))))))


  (it "remove-pane-collapses-parent-sibling-takes-over"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (win  (tl-window tree 24 81 :active (layout-leaf-pane l0))))
      (destructuring-bind (p0 p1) (window-panes win)
        (declare (ignore p0))
        (let ((survivor (window-remove-pane win (layout-leaf-pane l0))))
          (expect (eq p1 survivor))
          (expect (equal (list p1) (window-panes win)))
          (expect (= 0  (pane-x p1)))
          (expect (= 81 (pane-width p1)))
          (expect (= 24 (pane-height p1)))
          (expect (nerimux/layout::layout-leaf-p (window-tree win)))))))

  (it "remove-last-pane-empties-window"
    (let* ((leaf (tl-leaf 1 80 24))
           (win  (tl-window leaf 24 80 :active (layout-leaf-pane leaf))))
      (expect (null (window-remove-pane win (layout-leaf-pane leaf))))
      (expect (null (window-panes win)))
      (expect (null (window-tree win)))))

  (it "remove-pane-in-nested-tree-keeps-others"
    (let* ((top  (tl-leaf 1 1 1))
           (bl   (tl-leaf 2 1 1))
           (br   (tl-leaf 3 1 1))
           (tree (make-layout-split :v top (make-layout-split :h bl br)))
           (win  (tl-window tree 25 80)))
      (destructuring-bind (ptop pbl pbr) (window-panes win)
        (declare (ignore pbr))
        (window-remove-pane win (layout-leaf-pane br))
        (expect (equal (list ptop pbl) (window-panes win)))
        (expect (= 0  (pane-x pbl)))
        (expect (= 80 (pane-width pbl))))))


  (it "layout-min-extent-leaf"
    (let* ((p    (make-pane :id 1 :fd -1 :pid -1 :width 10 :height 5
                            :screen (make-screen 10 5)))
           (leaf (make-layout-leaf p)))
      (expect (= nerimux/layout::+pane-min-height+ (nerimux/layout::layout-min-extent leaf :v)))
      (expect (= nerimux/layout::+pane-min-width+  (nerimux/layout::layout-min-extent leaf :h)))))

  (it "layout-min-extent-same-axis-split"
    (let* ((l0 (tl-leaf 1 1 1))
           (l1 (tl-leaf 2 1 1))
           (split (make-layout-split :h l0 l1)))
      (expect (= 5 (nerimux/layout::layout-min-extent split :h)))
      (expect (= 1 (nerimux/layout::layout-min-extent split :v)))))

  (it "layout-min-extent-cross-axis-split"
    (let* ((l0 (tl-leaf 1 1 1))
           (l1 (tl-leaf 2 1 1))
           (split (make-layout-split :v l0 l1)))
      (expect (= 3 (nerimux/layout::layout-min-extent split :v)))
      (expect (= 2 (nerimux/layout::layout-min-extent split :h)))))


  (it "layout-find-leaf-table"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (p0   (layout-leaf-pane l0))
           (pabs (make-pane :id 99 :fd -1 :pid -1 :screen (make-screen 1 1))))
      (check-table (list (list (layout-find-leaf tree p0) l0 "present pane -> its leaf node")
                         (list (layout-find-leaf tree pabs) nil "absent pane -> NIL"))
                   :test #'eq))))

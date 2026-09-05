(in-package #:nerimux/test/model)

(describe "layout-tree-suite"


  (it "layout-split-default-ratio-is-one-half"
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (split (make-layout-split :h l0 l1)))
      (expect (= 1/2 (nerimux/layout::layout-split-ratio split)))))

  (it "layout-split-explicit-ratio-is-stored"
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (split (make-layout-split :h l0 l1 3/4)))
      (expect (= 3/4 (nerimux/layout::layout-split-ratio split)))))

  (it "layout-leaf-p-and-layout-split-p-predicates"
    (let* ((leaf  (tl-leaf 1 1 1))
           (split (make-layout-split :h leaf (tl-leaf 2 1 1))))
      (expect (nerimux/layout::layout-leaf-p  leaf))
      (expect (not (nerimux/layout::layout-split-p leaf)))
      (expect (nerimux/layout::layout-split-p split))
      (expect (not (nerimux/layout::layout-leaf-p  split)))))


  (it "checksum-constants-values"
    (expect (= 61    nerimux/layout::+checksum-multiplier+))
    (expect (= #xFFFF nerimux/layout::+checksum-mask+)))


  (it "pane-neighbor-returns-nil-in-zoomed-window"
    (with-h-split-window (win p0 p1)
      (setf (nerimux/window::window-zoom-p win) t)
      (expect (null (pane-neighbor win p0 :right)))
      (expect (null (pane-neighbor win p1 :left)))
      (setf (nerimux/window::window-zoom-p win) nil)))


  (it "pane-neighbor-v-split-up-down-symmetry"
    (with-v-split-window (win p0 p1)
      (expect (eq p1 (pane-neighbor win p0 :down)))
      (window-select-pane win p1)
      (expect (eq p0 (pane-neighbor win p1 :up)))))


  (it "neighbor-edge-tolerance-value"
    (expect (= 2 nerimux/window::+neighbor-edge-tolerance+)))


  (it "layout-split-axis-extent-nested-tree-h-outer"
    (let* ((left (tl-leaf 1 1 1))
           (top  (tl-leaf 2 1 1))
           (bot  (tl-leaf 3 1 1))
           (outer (make-layout-split :h left (make-layout-split :v top bot))))
      (nerimux/layout::layout-assign outer 0 0 81 25)
      (expect (= 81 (nerimux/layout::layout-split-axis-extent outer :h)))
      (expect (= 25 (nerimux/layout::layout-split-axis-extent outer :v))))))

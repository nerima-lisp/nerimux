(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "window-refresh-panes-derives-list-from-tree"
    (let* ((p0   (make-pane :id 1 :fd -1 :pid -1 :width 40 :height 24
                            :screen (make-screen 40 24)))
           (p1   (make-pane :id 2 :fd -1 :pid -1 :width 40 :height 24
                            :screen (make-screen 40 24)))
           (tree (make-layout-split :h (make-layout-leaf p0) (make-layout-leaf p1)))
           (win  (make-window :id 1 :name "w" :tree tree :panes nil)))
      (window-refresh-panes win)
      (expect (equal (list p0 p1) (window-panes win)))))


  (it "replace-in-tree-updates-parent-link"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (win  (make-window :id 1 :name "w" :tree tree :panes nil)))
      (let ((new-leaf (tl-leaf 3 1 1)))
        (nerimux/window::%replace-in-tree win l0 new-leaf)
        (expect (eq new-leaf (nerimux/layout::layout-split-first (window-tree win)))))))

  (it "collapse-parent-promotes-sibling"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (win  (make-window :id 1 :name "w" :tree tree :panes nil)))
      (let ((sibling (nerimux/window::%collapse-parent win tree :first)))
        (expect (eq l1 sibling))
        (expect (eq l1 (window-tree win)))))
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (win  (make-window :id 1 :name "w" :tree tree :panes nil)))
      (let ((sibling (nerimux/window::%collapse-parent win tree :second)))
        (expect (eq l0 sibling))
        (expect (eq l0 (window-tree win)))))))

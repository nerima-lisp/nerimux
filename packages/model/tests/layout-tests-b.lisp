(in-package #:nerimux/test/model)

(describe "layout-tree-suite"

  (it "layout-find-leaf-nil-node-arm-returns-nil"
    (let ((p (tl-pane 1 10 5)))
      (expect (null (layout-find-leaf nil p))))))

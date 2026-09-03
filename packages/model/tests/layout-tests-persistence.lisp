(in-package #:nerimux/test/model)

(describe "layout-tree-suite"


  (it "layout-to-string-single-leaf"
    (let* ((p    (tl-pane 7 20 10))
           (win  (tl-window (make-layout-leaf p) 10 20 :active p)))
      (let ((s (layout->string win)))
        (expect (stringp s))
        (expect (>= (length s) 5))
        (expect (char= #\, (char s 4)))
        (expect (search "20x10" s))
        (expect (search "7" s)))))

  (it "layout-to-string-nil-tree-returns-nil"
    (let ((win (make-window :id 1 :name "w" :width 80 :height 24 :tree nil)))
      (expect (null (layout->string win)))))

  (it "layout-to-string-split-notation"
    (dolist (c '((:h #\{ #\} "H-split uses braces")
                 (:v #\[ #\] "V-split uses brackets")))
      (destructuring-bind (orient open close label) c
        (declare (ignore label))
        (let* ((l0  (tl-leaf 1 1 1))
               (l1  (tl-leaf 2 1 1))
               (win (tl-window (make-layout-split orient l0 l1) 24 80))
               (s   (layout->string win)))
          (expect (find open  (coerce s 'list)))
          (expect (find close (coerce s 'list)))))))

  (it "layout-checksum-is-reproducible"
    (let ((s "%layout-checksum determinism check"))
      (expect (string= (nerimux/layout::%layout-checksum s)
                       (nerimux/layout::%layout-checksum s)))
      (expect (= 4 (length (nerimux/layout::%layout-checksum s))))))

  (it "layout-checksum-empty-string"
    (let ((cs (nerimux/layout::%layout-checksum "")))
      (expect (= 4 (length cs)))
      (expect (every (lambda (c) (digit-char-p c 16)) cs))))

  (it "build-flat-tree-single-pane"
    (let* ((p    (tl-pane 1 10 5))
           (tree (nerimux/layout::%build-flat-tree (list p) :h)))
      (expect (nerimux/layout::layout-leaf-p tree))
      (expect (eq p (layout-leaf-pane tree)))))

  (it "build-flat-tree-two-panes"
    (let* ((p0   (tl-pane 1 10 5))
           (p1   (tl-pane 2 10 5))
           (tree (nerimux/layout::%build-flat-tree (list p0 p1) :h)))
      (expect (nerimux/layout::layout-split-p tree))
      (expect (eq :h (nerimux/layout::layout-split-orientation tree)))
      (expect (eq p0 (layout-leaf-pane (nerimux/layout::layout-split-first tree))))
      (expect (nerimux/layout::layout-leaf-p (nerimux/layout::layout-split-second tree)))))

  (it "build-flat-tree-three-panes-is-right-leaning"
    (let* ((panes (loop for i from 1 to 3 collect (tl-pane i 10 5)))
           (tree  (nerimux/layout::%build-flat-tree panes :v)))
      (expect (nerimux/layout::layout-split-p tree))
      (expect (nerimux/layout::layout-split-p (nerimux/layout::layout-split-second tree)))
      (expect (nerimux/layout::layout-leaf-p (nerimux/layout::layout-split-first tree))))))

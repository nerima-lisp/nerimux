(in-package #:nerimux/test/renderer)

(defun %in-sel (row col sr er sc ec &optional rect-p)
  "Call in-selection-p with positional args in a more readable order."
  (nerimux/renderer::in-selection-p row col sr er sc ec rect-p))

(describe "renderer-suite"


  (it "render-v-separator-draws-horizontal-bar"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :v l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 80 21)
      (let ((buf (make-string-output-stream)))
        (nerimux/renderer::%render-v-separator buf tree nil 80)
        (let ((out (get-output-stream-string buf)))
          (expect (plusp (length out)))
          (expect (find #\─ out))))))


  (it "render-tree-borders-draws-horizontal-bar-for-v-split"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :v l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 80 21)
      (let ((out (render-tree-borders-output tree (layout-leaf-pane l0) 80)))
        (expect (plusp (length out)))
        (expect (find #\─ out)))))


  (it "layout-subtree-rect-single-leaf"
    (let* ((pane (tl-pane 7 40 20))
           (leaf (make-layout-leaf pane)))
      (nerimux/layout::layout-assign leaf 5 3 40 20)
      (let ((rect (nerimux/renderer::layout-subtree-rect leaf)))
        (check-table (list (list (getf rect :x) 5 ":x must match pane-x")
                           (list (getf rect :y) 3 ":y must match pane-y")
                           (list (getf rect :w) 40 ":w must match pane-width")
                           (list (getf rect :h) 20 ":h must match pane-height"))))))


  (it "subtree-contains-p-leaf-node-with-matching-pane"
    (let* ((p    (tl-pane 1 10 5))
           (leaf (make-layout-leaf p)))
      (expect (nerimux/renderer::subtree-contains-p leaf p) :to-be-truthy)))

  (it "subtree-contains-p-leaf-node-with-nonmatching-pane"
    (let* ((p1   (tl-pane 1 10 5))
           (p2   (tl-pane 2 10 5))
           (leaf (make-layout-leaf p1)))
      (expect (nerimux/renderer::subtree-contains-p leaf p2) :to-be-falsy)))


  (it "in-selection-p-table"
    (dolist (c '(;; single-row selection (sr = er = 2, sc=1, ec=5)
                 (t   2 3 2 2 1 5 nil "single-row inside [1,5)")
                 (t   2 1 2 2 1 5 nil "single-row at left boundary (inclusive)")
                 (nil 2 5 2 2 1 5 nil "single-row at right boundary (exclusive)")
                 (nil 2 0 2 2 1 5 nil "single-row before sc")
                 (t   0 3 0 2 2 4 nil "first row, col >= sc")
                 (nil 0 1 0 2 2 4 nil "first row, col < sc")
                 (t   2 3 0 2 2 4 nil "last row, col < ec")
                 (nil 2 4 0 2 2 4 nil "last row, col = ec (exclusive)")
                 (t   1 0 0 2 2 4 nil "middle row, col 0 (full row)")
                 (t   1 7 0 2 2 4 nil "middle row, col 7 (full row)")
                 (nil 0 0 1 3 0 5 nil "row before sr")
                 (nil 4 0 1 3 0 5 nil "row after er")
                 (t   2 3 1 4 2 6 t   "rect inside box")
                 (t   2 2 1 4 2 6 t   "rect col at sc (inclusive)")
                 (nil 2 6 1 4 2 6 t   "rect col at ec (exclusive)")
                 (t   1 3 1 4 2 6 t   "rect start row included")
                 (t   4 3 1 4 2 6 t   "rect end row included")
                 (nil 2 1 1 4 2 6 t   "rect col before sc")
                 (nil 2 7 1 4 2 6 t   "rect col after ec")
                 (nil 0 3 1 4 2 6 t   "rect row before sr")
                 (nil 5 3 1 4 2 6 t   "rect row after er")
                 (t   2 4 1 4 2 6 t   "rect middle row, col in range")
                 (nil 2 0 1 4 2 6 t   "rect middle row, col out of range")))
      (destructuring-bind (expected row col sr er sc ec rect-p desc) c
        (declare (ignore desc))
        (if expected
            (expect (%in-sel row col sr er sc ec rect-p) :to-be-truthy)
            (expect (%in-sel row col sr er sc ec rect-p) :to-be-falsy)))))


  (it "compute-selection-bounds-active-selection"
    (let ((screen (make-selecting-screen 10 5 1 2 3 4)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore mark-row mark-col))
        (expect active :to-be-truthy)
        (expect rect-p :to-be-falsy)
        (check-table (list (list sr 1 "start row must be min(mark-row, cursor-row)")
                           (list er 3 "end row must be max(mark-row, cursor-row)")
                           (list sc 2 "start col: mark-col when mark-row < cursor-row")
                           (list ec 4 "end col: cursor-col when mark-row < cursor-row"))))))

  (it "compute-selection-bounds-no-selecting"
    (let ((screen (make-screen 10 5)))
      (setf (nerimux/terminal/types:screen-copy-selecting screen) nil
            (nerimux/terminal/types:screen-copy-mark      screen) (cons 0 0)
            (nerimux/terminal/types:screen-copy-cursor    screen) (cons 1 1))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sr er sc ec rect-p mark-row mark-col))
        (expect active :to-be-falsy))))

  (it "compute-selection-bounds-nil-mark"
    (let ((screen (make-screen 10 5)))
      (setf (nerimux/terminal/types:screen-copy-selecting screen) t
            (nerimux/terminal/types:screen-copy-mark      screen) nil
            (nerimux/terminal/types:screen-copy-cursor    screen) (cons 1 1))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sr er sc ec rect-p mark-row mark-col))
        (expect active :to-be-falsy))))

  (it "compute-selection-bounds-reversed-rows-normalised"
    (let ((screen (make-selecting-screen 10 5 3 5 1 2)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore rect-p mark-row mark-col))
        (expect active :to-be-truthy)
        (expect (<= sr er))
        (check-table (list (list sr 1 "start row must be min(mark-row=3, cursor-row=1)=1")
                           (list er 3 "end row must be max(mark-row=3, cursor-row=1)=3")
                           (list sc 2 "start col = cursor-col when cursor-row < mark-row")
                           (list ec 5 "end col = mark-col when cursor-row < mark-row"))))))

  (it "compute-selection-bounds-same-row-cols-normalised"
    (let ((screen (make-selecting-screen 10 5 2 7 2 3)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore rect-p mark-row mark-col))
        (expect active :to-be-truthy)
        (check-table (list (list sr 2 "both rows are 2: start")
                           (list er 2 "both rows are 2: end")
                           (list sc 3 "start col = min(mark-col=7, cursor-col=3)=3")
                           (list ec 7 "end col = max(mark-col=7, cursor-col=3)=7"))))))

  (it "compute-selection-bounds-copy-offset-applied"
    (let ((screen (make-selecting-screen 10 5 4 0 2 0 :offset 2)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sc ec rect-p mark-col))
        (expect active :to-be-truthy)
        (expect (= 2 sr))
        (expect (= 4 er))
        (expect (= 4 mark-row)))))

  (it "compute-selection-bounds-rect-columns-symmetric"
    (let ((screen (make-selecting-screen 10 6 1 6 4 2 :rect t)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore mark-row mark-col))
        (expect active :to-be-truthy)
        (expect rect-p :to-be-truthy)
        (check-table (list (list sr 1 "start row = min(1,4) = 1")
                           (list er 4 "end row = max(1,4) = 4")
                           (list sc 2 "start col = min(mark-col=6, cursor-col=2) = 2")
                           (list ec 7 "end col = 1+max(6,2) = 7 (exclusive)"))
                     :test #'equal))))

  (it "compute-selection-bounds-rect-columns-reversed"
    (let ((screen (make-selecting-screen 10 8 2 3 5 8 :rect t)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sr er mark-row mark-col))
        (expect active :to-be-truthy)
        (expect rect-p :to-be-truthy)
        (expect (= 3 sc))
        (expect (= 9 ec)))))


  (it "make-test-pane-creates-correct-geometry"
    (let ((pane (make-test-pane 20 5 :id 7 :x 3 :y 2)))
      (check-table (list (list (pane-width  pane) 20 "pane width must be 20")
                         (list (pane-height pane)  5 "pane height must be 5")
                         (list (pane-id     pane)  7 "pane id must be 7")
                         (list (pane-x      pane)  3 "pane x must be 3")
                         (list (pane-y      pane)  2 "pane y must be 2"))
                   :test #'equal)
      (expect (screen-p (pane-screen pane)))))

  (it "make-test-pane-feeds-content"
    (let* ((pane   (make-test-pane 10 5 :content "AB"))
           (screen (pane-screen pane)))
      (expect (char= #\A (cell-char (screen-cell screen 0 0))))
      (expect (char= #\B (cell-char (screen-cell screen 1 0))))))

  (it "make-selecting-screen-sets-selection-state"
    (let ((screen (make-selecting-screen 10 5 1 2 3 4)))
      (expect (nerimux/terminal/types:screen-copy-selecting screen) :to-be-truthy)
      (expect (equal (cons 1 2) (nerimux/terminal/types:screen-copy-mark screen)))
      (expect (equal (cons 3 4) (nerimux/terminal/types:screen-copy-cursor screen)))
      (expect (= 0 (nerimux/terminal/types:screen-copy-offset screen)))))

  (it "make-selecting-screen-custom-offset"
    (let ((screen (make-selecting-screen 10 5 0 0 1 0 :offset 7)))
      (expect (= 7 (nerimux/terminal/types:screen-copy-offset screen)))))


  (it "all-match-ranges-literal-and-regex"
    (expect (equal '((0 . 3) (8 . 11))
               (nerimux/renderer::%all-match-ranges "abc" "abc def abc")))
    (expect (equal '((4 . 7))
               (nerimux/renderer::%all-match-ranges "[0-9]+" "abc 123 xyz")))
    (expect (equal '((2 . 3))
               (nerimux/renderer::%all-match-ranges "(" "a ( b")))))

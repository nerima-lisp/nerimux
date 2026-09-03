(in-package #:nerimux/test/renderer)

;;;; renderer-pane tests — part B: %render-v-separator,
;;;; render-tree-borders with :v split, layout-subtree-rect single-leaf,
;;;; subtree-contains-p nil-pane corner case, additional in-sel/pane/border coverage.
;;;;
;;;; R6.6 deleted pane-border-status/pane-border-format outright (no label is
;;;; ever drawn on a border) and R2.4 deleted the pane-border-lines glyph
;;;; dispatch (%dispatch-pane-border-chars) — see renderer-borders.lisp and
;;;; renderer-pane-tests.lisp's header.
(defun %in-sel (row col sr er sc ec &optional rect-p)
  "Call in-selection-p with positional args in a more readable order."
  (nerimux/renderer::in-selection-p row col sr er sc ec rect-p))

(describe "renderer-suite"

  ;;; -- %render-v-separator branch coverage ------------------------------------

  ;; %render-v-separator draws ─ characters between top and bottom children.
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

  ;;; -- render-tree-borders with :v split --------------------------------------

  ;; render-tree-borders draws ─ separators for a :v split.
  (it "render-tree-borders-draws-horizontal-bar-for-v-split"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :v l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 80 21)
      (let ((out (render-tree-borders-output tree (layout-leaf-pane l0) 80)))
        (expect (plusp (length out)))
        (expect (find #\─ out)))))

  ;;; -- layout-subtree-rect single-leaf edge case ------------------------------

  ;; layout-subtree-rect on a single leaf returns the leaf pane geometry.
  (it "layout-subtree-rect-single-leaf"
    (let* ((pane (tl-pane 7 40 20))
           (leaf (make-layout-leaf pane)))
      (nerimux/layout::layout-assign leaf 5 3 40 20)
      (let ((rect (nerimux/renderer::layout-subtree-rect leaf)))
        (check-table (list (list (getf rect :x) 5 ":x must match pane-x")
                           (list (getf rect :y) 3 ":y must match pane-y")
                           (list (getf rect :w) 40 ":w must match pane-width")
                           (list (getf rect :h) 20 ":h must match pane-height"))))))

  ;;; -- subtree-contains-p nil pane corner case --------------------------------

  ;; subtree-contains-p returns T when the subtree is a leaf containing the pane.
  (it "subtree-contains-p-leaf-node-with-matching-pane"
    (let* ((p    (tl-pane 1 10 5))
           (leaf (make-layout-leaf p)))
      (expect (nerimux/renderer::subtree-contains-p leaf p) :to-be-truthy)))

  ;; subtree-contains-p returns NIL when the subtree is a leaf for a different pane.
  (it "subtree-contains-p-leaf-node-with-nonmatching-pane"
    (let* ((p1   (tl-pane 1 10 5))
           (p2   (tl-pane 2 10 5))
           (leaf (make-layout-leaf p1)))
      (expect (nerimux/renderer::subtree-contains-p leaf p2) :to-be-falsy)))

  ;;; -- in-selection-p direct unit tests ----------------------------------------
  ;;;
  ;;; in-selection-p is the innermost hot path: test all 4 cond branches directly.

  ;; in-selection-p covers all four cond branches (single-row, first/last/mid row, rect mode).
  ;; Each row is (expected row col sr er sc ec rect-p description).
  (it "in-selection-p-table"
    (dolist (c '(;; single-row selection (sr = er = 2, sc=1, ec=5)
                 (t   2 3 2 2 1 5 nil "single-row inside [1,5)")
                 (t   2 1 2 2 1 5 nil "single-row at left boundary (inclusive)")
                 (nil 2 5 2 2 1 5 nil "single-row at right boundary (exclusive)")
                 (nil 2 0 2 2 1 5 nil "single-row before sc")
                 ;; multi-row: sr=0, er=2, sc=2, ec=4
                 (t   0 3 0 2 2 4 nil "first row, col >= sc")
                 (nil 0 1 0 2 2 4 nil "first row, col < sc")
                 (t   2 3 0 2 2 4 nil "last row, col < ec")
                 (nil 2 4 0 2 2 4 nil "last row, col = ec (exclusive)")
                 (t   1 0 0 2 2 4 nil "middle row, col 0 (full row)")
                 (t   1 7 0 2 2 4 nil "middle row, col 7 (full row)")
                 (nil 0 0 1 3 0 5 nil "row before sr")
                 (nil 4 0 1 3 0 5 nil "row after er")
                 ;; rectangle mode: sr=1, er=4, sc=2, ec=6
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

  ;;; -- %compute-selection-bounds unit tests ------------------------------------

  ;; %compute-selection-bounds returns sel-active=T when all prerequisites are present.
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

  ;; %compute-selection-bounds returns sel-active=NIL when copy-selecting is NIL.
  (it "compute-selection-bounds-no-selecting"
    (let ((screen (make-screen 10 5)))
      (setf (nerimux/terminal/types:screen-copy-selecting screen) nil
            (nerimux/terminal/types:screen-copy-mark      screen) (cons 0 0)
            (nerimux/terminal/types:screen-copy-cursor    screen) (cons 1 1))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sr er sc ec rect-p mark-row mark-col))
        (expect active :to-be-falsy))))

  ;; %compute-selection-bounds returns sel-active=NIL when mark is NIL.
  (it "compute-selection-bounds-nil-mark"
    (let ((screen (make-screen 10 5)))
      (setf (nerimux/terminal/types:screen-copy-selecting screen) t
            (nerimux/terminal/types:screen-copy-mark      screen) nil
            (nerimux/terminal/types:screen-copy-cursor    screen) (cons 1 1))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sr er sc ec rect-p mark-row mark-col))
        (expect active :to-be-falsy))))

  ;; %compute-selection-bounds normalises row order so start <= end.
  (it "compute-selection-bounds-reversed-rows-normalised"
    ;; cursor above mark — rows should be swapped in the output
    (let ((screen (make-selecting-screen 10 5 3 5 1 2)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore rect-p mark-row mark-col))
        (expect active :to-be-truthy)
        (expect (<= sr er))
        ;; cursor-row < mark-row: start-col = cursor-col, end-col = mark-col
        (check-table (list (list sr 1 "start row must be min(mark-row=3, cursor-row=1)=1")
                           (list er 3 "end row must be max(mark-row=3, cursor-row=1)=3")
                           (list sc 2 "start col = cursor-col when cursor-row < mark-row")
                           (list ec 5 "end col = mark-col when cursor-row < mark-row"))))))

  ;; %compute-selection-bounds normalises col order for same-row selections.
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

  ;; %compute-selection-bounds maps virtual rows to viewport rows using the CURRENT offset.
  ;; The returned mark row is the clamped viewport row even when the virtual mark row
  ;; falls outside the visible pane.
  (it "compute-selection-bounds-copy-offset-applied"
    ;; No scrollback.  mark=(4,0) was set when offset=0 (mark-offset=0 by default).
    ;; Current offset=2, cursor=(2,0).
    (let ((screen (make-selecting-screen 10 5 4 0 2 0 :offset 2)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sc ec rect-p mark-col))
        (expect active :to-be-truthy)
        (expect (= 2 sr))
        (expect (= 4 er))
        (expect (= 4 mark-row)))))

  ;; %compute-selection-bounds uses min/max column symmetrically in rectangle mode.
  (it "compute-selection-bounds-rect-columns-symmetric"
    ;; mark at (row=1, col=6), cursor at (row=4, col=2): rect cols [2,7) inclusive
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

  ;; %compute-selection-bounds swaps columns correctly when cursor-col > mark-col in rect mode.
  (it "compute-selection-bounds-rect-columns-reversed"
    ;; mark at (row=2, col=3), cursor at (row=5, col=8)
    (let ((screen (make-selecting-screen 10 8 2 3 5 8 :rect t)))
      (multiple-value-bind (active sr er sc ec rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds screen)
        (declare (ignore sr er mark-row mark-col))
        (expect active :to-be-truthy)
        (expect rect-p :to-be-truthy)
        (expect (= 3 sc))
        (expect (= 9 ec)))))

  ;;; -- make-test-pane and make-selecting-screen fixture helpers -------------------

  ;; make-test-pane returns a pane with the requested width, height, id, and origin.
  (it "make-test-pane-creates-correct-geometry"
    (let ((pane (make-test-pane 20 5 :id 7 :x 3 :y 2)))
      (check-table (list (list (pane-width  pane) 20 "pane width must be 20")
                         (list (pane-height pane)  5 "pane height must be 5")
                         (list (pane-id     pane)  7 "pane id must be 7")
                         (list (pane-x      pane)  3 "pane x must be 3")
                         (list (pane-y      pane)  2 "pane y must be 2"))
                   :test #'equal)
      (expect (screen-p (pane-screen pane)))))

  ;; make-test-pane feeds :content into the pane screen.
  (it "make-test-pane-feeds-content"
    (let* ((pane   (make-test-pane 10 5 :content "AB"))
           (screen (pane-screen pane)))
      (expect (char= #\A (cell-char (screen-cell screen 0 0))))
      (expect (char= #\B (cell-char (screen-cell screen 1 0))))))

  ;; make-selecting-screen returns a screen with copy-selecting T and the given mark/cursor.
  (it "make-selecting-screen-sets-selection-state"
    (let ((screen (make-selecting-screen 10 5 1 2 3 4)))
      (expect (nerimux/terminal/types:screen-copy-selecting screen) :to-be-truthy)
      (expect (equal (cons 1 2) (nerimux/terminal/types:screen-copy-mark screen)))
      (expect (equal (cons 3 4) (nerimux/terminal/types:screen-copy-cursor screen)))
      (expect (= 0 (nerimux/terminal/types:screen-copy-offset screen)))))

  ;; make-selecting-screen respects the :offset keyword.
  (it "make-selecting-screen-custom-offset"
    (let ((screen (make-selecting-screen 10 5 0 0 1 0 :offset 7)))
      (expect (= 7 (nerimux/terminal/types:screen-copy-offset screen)))))

  ;;; -- copy-mode search-match highlighting -------------------------------------

  ;; %all-match-ranges returns every match span; regex with literal fallback.
  (it "all-match-ranges-literal-and-regex"
    (expect (equal '((0 . 3) (8 . 11))
               (nerimux/renderer::%all-match-ranges "abc" "abc def abc")))
    (expect (equal '((4 . 7))
               (nerimux/renderer::%all-match-ranges "[0-9]+" "abc 123 xyz")))
    (expect (equal '((2 . 3))
               (nerimux/renderer::%all-match-ranges "(" "a ( b")))))

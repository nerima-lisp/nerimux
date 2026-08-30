(in-package #:nerimux/test/model)

;;;; layout tests — part C: layout persistence internals (split-bounding-box,
;;;; node-to-string) and layout-find-parent deep-tree traversal.

(describe "layout-tree-suite"

  ;;; ── Layout persistence: internal helpers ─────────────────────────────────────

  ;; layout-node-bounding-box derives correct bounding box for both :h and :v splits.
  (it "split-bounding-box-table"
    (dolist (row '((:h  5  3  40 12   5  3  40 12 ":h split")
                   (:v  0  0  80 21   0  0  80 21 ":v split")))
      (destructuring-bind (orient x y w h exp-x exp-y exp-w exp-h desc) row
        (declare (ignore desc))
        (let* ((l0   (tl-leaf 1 1 1))
               (l1   (tl-leaf 2 1 1))
               (tree (make-layout-split orient l0 l1)))
          (nerimux/layout::layout-assign tree x y w h)
          (multiple-value-bind (min-x min-y width height)
              (layout-node-bounding-box tree)
            (expect (= exp-x min-x))
            (expect (= exp-y min-y))
            (expect (= exp-w width))
            (expect (= exp-h height)))))))

  ;; layout-node-bounding-box on an inner split must aggregate the min/max of ITS OWN
  ;; leaves, not merely echo back the outer layout-assign() rectangle passed at
  ;; the root. Tree: (outer :h (l0) (inner :v (l1) (l2))), assigned at 0,0,81,21.
  ;; l0 occupies the left 40 cols; inner (l1 over l2) occupies the right 40 cols
  ;; starting at x=41 — so inner's own bounding box (x=41, w=40) genuinely differs
  ;; from the outer rectangle (x=0, w=81) that was passed to layout-assign.
  (it "split-bounding-box-aggregates-nested-subtree-not-top-level-assign"
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (l2    (tl-leaf 3 1 1))
           (inner (make-layout-split :v l1 l2))
           (outer (make-layout-split :h l0 inner)))
      (nerimux/layout::layout-assign outer 0 0 81 21)
      ;; Sanity: outer's own bounding box does equal the top-level assign rectangle.
      (multiple-value-bind (ox oy ow oh) (layout-node-bounding-box outer)
        (expect (= 0  ox))
        (expect (= 0  oy))
        (expect (= 81 ow))
        (expect (= 21 oh)))
      ;; The real assertion: inner's bounding box is computed from its own two
      ;; leaves (l1, l2), which occupy only the right half of the outer rectangle —
      ;; a bug in min/max aggregation across children would not shrink this to
      ;; match l1/l2's actual x/width and would instead leak the outer values.
      (multiple-value-bind (ix iy iw ih) (layout-node-bounding-box inner)
        (expect (= 41 ix))
        (expect (= 0  iy))
        (expect (= 40 iw))
        (expect (= 21 ih)))))

  ;; %node->string formats a leaf's WxH,X,Y,id fragment and returns empty string for NIL.
  (it "node-to-string-leaf-and-nil"
    (let* ((p    (tl-pane 7 20 10))
           (leaf (make-layout-leaf p)))
      (nerimux/layout::layout-assign leaf 3 5 20 10)
      (let ((s (nerimux/layout::%node->string leaf)))
        (expect (stringp s))
        (expect (search "20x10" s))
        (expect (search ",3,5," s))
        (expect (search "7" s))))
    (expect (string= "" (nerimux/layout::%node->string nil))))

  ;;; ── layout-find-parent deep tree ─────────────────────────────────────────────

  ;; layout-find-parent correctly climbs into a nested tree to find the parent.
  (it "layout-find-parent-in-nested-tree-finds-correct-parent"
    ;; Tree: (outer :h (l0) (inner :v (l1) (l2)))
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (l2    (tl-leaf 3 1 1))
           (inner (make-layout-split :v l1 l2))
           (outer (make-layout-split :h l0 inner)))
      ;; l1 is :first child of inner (not of outer).
      (multiple-value-bind (p s) (layout-find-parent outer l1)
        (expect (eq inner p))
        (expect (eq :first s)))
      ;; l2 is :second child of inner.
      (multiple-value-bind (p s) (layout-find-parent outer l2)
        (expect (eq inner p))
        (expect (eq :second s)))
      ;; inner itself is :second child of outer.
      (multiple-value-bind (p s) (layout-find-parent outer inner)
        (expect (eq outer p))
        (expect (eq :second s)))))

  ;; layout-find-parent on a bare leaf (no splits) always returns (NIL NIL).
  (it "layout-find-parent-leaf-node-returns-nil"
    (let* ((leaf   (tl-leaf 1 1 1))
           (target (tl-leaf 2 1 1)))
      (multiple-value-bind (p s) (layout-find-parent leaf target)
        (expect (null p))
        (expect (null s)))))

  ;;; ── define-axis-rules / %split-fits-p ────────────────────────────────────────

  ;; %split-fits-p: T when room exists to split on the axis, NIL when too small.
  ;; min-width=2 → h needs ≥5 cols; min-height=1 → v needs ≥3 rows.
  (it "split-fits-p-layout-tree-suite"
    (dolist (row '((t   5 24 :h "5-col pane fits h-split (needs 5)")
                   (nil 4 24 :h "4-col pane too narrow for h-split (needs 5)")
                   (t  80  3 :v "3-row pane fits v-split (needs 3)")
                   (nil 80  2 :v "2-row pane too short for v-split (needs 3)")))
      (destructuring-bind (expected width height orient desc) row
        (declare (ignore desc))
        (let ((pane (make-pane :id 1 :fd -1 :pid -1 :width width :height height
                               :screen (make-screen width height))))
          (expect (eq expected (nerimux/window::%split-fits-p pane orient)))))))

  ;;; ── Table-driven: %layout-checksum known-value tests ─────────────────────────

  ;; %layout-checksum produces the canonical 4-hex layout checksum.
  (it "layout-checksum-known-values-match-expected"
    (dolist (c (list (list ""           "0000" "empty string checksum must be 0000")
                     (list "a"         "0061" "single-char 'a' (97 decimal = 0x61)")
                     (let ((s "1x1,0,0,1"))
                       (list s (nerimux/layout::%layout-checksum s) "checksum must be deterministic"))))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (string= expected (nerimux/layout::%layout-checksum input))))))

  ; resize-direction-orientation-all-directions-table removed.
  ; The identical 4-case mapping is already tested in layout-geometry-tests.lisp
  ; as resize-direction-orientation-mapping; the duplicate was removed.
  )

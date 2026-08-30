(in-package #:nerimux/test/model)

;;;; layout tests — part D: layout-split struct defaults, checksum constants,
;;;; zoomed-window pane-neighbor guard, +neighbor-edge-tolerance+ constant,
;;;; pane-neighbor up/down symmetry, layout-split-axis-extent, and layout-split
;;;; type predicates.

(describe "layout-tree-suite"

  ;;; ── layout-split struct defaults ─────────────────────────────────────────────

  ;; make-layout-split with 2 args uses the default ratio of 1/2.
  (it "layout-split-default-ratio-is-one-half"
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (split (make-layout-split :h l0 l1)))
      (expect (= 1/2 (nerimux/layout::layout-split-ratio split)))))

  ;; make-layout-split with an explicit ratio stores it verbatim.
  (it "layout-split-explicit-ratio-is-stored"
    (let* ((l0    (tl-leaf 1 1 1))
           (l1    (tl-leaf 2 1 1))
           (split (make-layout-split :h l0 l1 3/4)))
      (expect (= 3/4 (nerimux/layout::layout-split-ratio split)))))

  ;; layout-leaf-p and layout-split-p correctly identify node types.
  (it "layout-leaf-p-and-layout-split-p-predicates"
    (let* ((leaf  (tl-leaf 1 1 1))
           (split (make-layout-split :h leaf (tl-leaf 2 1 1))))
      (expect (nerimux/layout::layout-leaf-p  leaf))
      (expect (not (nerimux/layout::layout-split-p leaf)))
      (expect (nerimux/layout::layout-split-p split))
      (expect (not (nerimux/layout::layout-leaf-p  split)))))

  ;;; ── Persistence: checksum constants ────────────────────────────────────────────

  ;; Layout persistence constants have the canonical checksum values.
  (it "checksum-constants-values"
    (expect (= 61    nerimux/layout::+checksum-multiplier+))
    (expect (= #xFFFF nerimux/layout::+checksum-mask+)))

  ;;; ── pane-neighbor: zoomed window guard ──────────────────────────────────────────

  ;; pane-neighbor returns NIL immediately when the window is zoomed.
  (it "pane-neighbor-returns-nil-in-zoomed-window"
    ;; Build a 2-pane window and toggle zoom; pane-neighbor must not find any neighbor.
    (with-h-split-window (win p0 p1)
      ;; Manually set the zoom flag (without a real PTY resize).
      (setf (nerimux/window::window-zoom-p win) t)
      (expect (null (pane-neighbor win p0 :right)))
      (expect (null (pane-neighbor win p1 :left)))
      ;; Cleanup: restore zoom flag so state does not leak.
      (setf (nerimux/window::window-zoom-p win) nil)))

  ;;; ── pane-neighbor: up/down symmetry ─────────────────────────────────────────

  ;; pane-neighbor is symmetric: down neighbor of top is bottom, up neighbor of bottom is top.
  (it "pane-neighbor-v-split-up-down-symmetry"
    (with-v-split-window (win p0 p1)
      (expect (eq p1 (pane-neighbor win p0 :down)))
      (window-select-pane win p1)
      (expect (eq p0 (pane-neighbor win p1 :up)))))

  ;;; ── +neighbor-edge-tolerance+ constant ──────────────────────────────────────

  ;; +neighbor-edge-tolerance+ must be 2 to account for the 1-cell separator.
  (it "neighbor-edge-tolerance-value"
    (expect (= 2 nerimux/window::+neighbor-edge-tolerance+)))

  ;;; ── layout-split-axis-extent: nested tree ────────────────────────────────────

  ;; layout-split-axis-extent on an outer :h tree covers the full window width.
  (it "layout-split-axis-extent-nested-tree-h-outer"
    ;; (left | (top / bot)): outer :h, inner :v.  Total :h extent = full window width.
    (let* ((left (tl-leaf 1 1 1))
           (top  (tl-leaf 2 1 1))
           (bot  (tl-leaf 3 1 1))
           (outer (make-layout-split :h left (make-layout-split :v top bot))))
      (nerimux/layout::layout-assign outer 0 0 81 25)
      ;; :h extent of the outer split = full width = 81.
      (expect (= 81 (nerimux/layout::layout-split-axis-extent outer :h)))
      ;; :v extent = full height = 25.
      (expect (= 25 (nerimux/layout::layout-split-axis-extent outer :v))))))

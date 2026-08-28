(in-package #:nerimux/model)

;;; ── Layout tree ────────────────────────────────────────────────────────────
;;;
;;; A window's geometry is a BINARY SPLIT TREE.  Every leaf wraps exactly one
;;; pane; every internal node splits its rectangle into two children along one
;;; axis at a fractional ratio.  This lets a split halve ONLY the active pane's
;;; rectangle and supports arbitrary nested/mixed layouts (a pane split top/
;;; bottom, one half then split left/right, …).
;;;
;;; Orientations use -v/-h naming so the keywords are not inverted:
;;;   :v  — top/bottom split  (children stacked vertically; the divider runs
;;;         horizontally)
;;;   :h  — left/right split  (children side by side; the divider runs
;;;         vertically)

(defconstant +pane-min-width+  2
  "Smallest interior width (columns) a pane may occupy.")
(defconstant +pane-min-height+ 1
  "Smallest interior height (rows) a pane may occupy.")

(defstruct (layout-leaf (:constructor make-layout-leaf (pane)))
  "Tree leaf: owns one PANE."
  pane)

(defstruct (layout-split (:constructor make-layout-split (orientation first second
                                                          &optional (ratio 1/2))))
  "Internal node: split ORIENTATION (:v top/bottom, :h left/right) between two
   children FIRST and SECOND, giving FIRST the fraction RATIO of the split axis."
  orientation
  first
  second
  (ratio 1/2))

(defun %direct-child-side (split child)
  "If CHILD is a direct child of SPLIT, return (values SPLIT :first or :second).
   Returns (values NIL NIL) when CHILD is not a direct child of SPLIT."
  (cond ((eq (layout-split-first  split) child) (values split :first))
        ((eq (layout-split-second split) child) (values split :second))
        (t (values nil nil))))

(defun layout-find-parent (node child)
  "Return (values PARENT WHICH) for CHILD's immediate parent LAYOUT-SPLIT,
   where WHICH is :first or :second.  Returns (values NIL NIL) when not found."
  (when (layout-split-p node)
    ;; Check direct children.  Note: OR cannot be used here — it only propagates
    ;; the primary value, discarding the secondary :first/:second.
    (multiple-value-bind (p s) (%direct-child-side node child)
      (if p
          (values p s)
          (multiple-value-bind (p2 s2) (layout-find-parent (layout-split-first node) child)
            (if p2 (values p2 s2)
                (layout-find-parent (layout-split-second node) child)))))))

;;; ── orient-case: concise :h/:v dispatch ────────────────────────────────────
;;;
;;; Defined here (layout.lisp, the earliest-loading layout file) so that every
;;; later file — layout-geometry.lisp, window-core.lisp, window-tree.lisp, window-layout.lisp —
;;; can use it without forward-reference issues.
;;;
;;; Pattern (Prolog analogy):
;;;   orient_case(:h, H-form).
;;;   orient_case(:v, V-form).
;;;
;;; Expands to: (ecase ORIENT-VAR (:h H-FORM) (:v V-FORM))

(defmacro orient-case (orient-var &key h v)
  "Dispatch on ORIENT-VAR (:h or :v), evaluating H or V respectively.
   A concise replacement for repeated (ecase orient (:h ...) (:v ...))."
  `(ecase ,orient-var
     (:h ,h)
     (:v ,v)))
;;; ── Tree geometry: assign rectangles ───────────────────────────────────────

;;; ── %axis-floor: pure data lookup ───────────────────────────────────────────
;;;
;;; A Prolog-like fact:
;;;   axis_floor(:v) :- +pane-min-height+.
;;;   axis_floor(:h) :- +pane-min-width+.

(defun %axis-floor (orient)
  "Minimum pane extent (cells) along ORIENT's split axis: rows for :v, cols for :h."
  (orient-case orient :h +pane-min-width+ :v +pane-min-height+))

;;; ── %build-flat-tree ─────────────────────────────────────────────────────────
;;;
;;; A pure tree-construction helper that only needs layout types
;;; (make-layout-leaf, make-layout-split), so it belongs here rather than in a
;;; file that pulls in WINDOW struct accessors.

(defun %build-flat-tree (panes orientation)
  "Build a right-leaning binary split chain from PANES using ORIENTATION.
   Single pane: return a layout-leaf.  Two or more: first pane is the
   left/top leaf; the rest recurse as the right/bottom subtree."
  (if (null (rest panes))
      (make-layout-leaf (first panes))
      (make-layout-split orientation
                         (make-layout-leaf (first panes))
                         (%build-flat-tree (rest panes) orientation))))

;;; Layout persistence (serialization) lives in layout-persistence.lisp,
;;; which is loaded immediately after this file.  That file defines:
;;;   %layout-checksum, layout-node-bounding-box, %node->string, layout->string.

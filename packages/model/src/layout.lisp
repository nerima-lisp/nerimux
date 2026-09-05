(in-package #:nerimux/layout)

(defconstant +pane-min-width+
  2
  "Smallest interior width (columns) a pane may occupy.")

(defconstant +pane-min-height+
  1
  "Smallest interior height (rows) a pane may occupy.")

(defstruct (layout-leaf (:constructor make-layout-leaf (pane)))
  "Tree leaf: owns one PANE."
  pane)

(defstruct 
    (layout-split
     (:constructor make-layout-split
                   (orientation first second &optional (ratio 1/2))))
  "Internal node: split ORIENTATION (:v top/bottom, :h left/right) between two
   children FIRST and SECOND, giving FIRST the fraction RATIO of the split axis."
  orientation
  first
  second
  (ratio 1/2))

(defun %direct-child-side (split child)
  "If CHILD is a direct child of SPLIT, return (values SPLIT :first or :second).
   Returns (values NIL NIL) when CHILD is not a direct child of SPLIT."
  (cond
    ((eq (layout-split-first split) child) (values split :first))
    ((eq (layout-split-second split) child) (values split :second))
    (t (values nil nil))))

(defun layout-find-parent (node child)
  "Return (values PARENT WHICH) for CHILD's immediate parent LAYOUT-SPLIT,
   where WHICH is :first or :second.  Returns (values NIL NIL) when not found."
  (when (layout-split-p node)
    (multiple-value-bind (p s) (%direct-child-side node child)
      (if p
          (values p s)
          (multiple-value-bind (p2 s2) (layout-find-parent (layout-split-first node) child)
            (if p2 (values p2 s2)
                (layout-find-parent (layout-split-second node) child)))))))

(defmacro orient-case (orient-var &key h v)
  "Dispatch on ORIENT-VAR (:h or :v), evaluating H or V respectively.
   A concise replacement for repeated (ecase orient (:h ...) (:v ...))."
  `(ecase ,orient-var
     (:h ,h)
     (:v ,v)))

(defun %axis-floor (orient)
  "Minimum pane extent (cells) along ORIENT's split axis: rows for :v, cols for :h."
  (orient-case orient :h +pane-min-width+ :v +pane-min-height+))

(defun %build-flat-tree (panes orientation)
  "Build a right-leaning binary split chain from PANES using ORIENTATION.
   Single pane: return a layout-leaf.  Two or more: first pane is the
   left/top leaf; the rest recurse as the right/bottom subtree."
  (if (null (rest panes))
      (make-layout-leaf (first panes))
      (make-layout-split orientation
                         (make-layout-leaf (first panes))
                         (%build-flat-tree (rest panes) orientation))))

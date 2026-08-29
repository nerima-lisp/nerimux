(in-package #:nerimux/window)

(defun window-refresh-panes (window)
  "Recompute WINDOW's derived PANES list from its TREE (when present)."
  (when (window-tree window)
    (setf (window-panes window) (layout-leaves (window-tree window))))
  (window-panes window))

(defun window-active-pane (window)
  "Return WINDOW's active pane, falling back to the first pane when active is NIL."
  (or (window-active window)
      (first (window-panes window))))

(defun window-select-pane (window pane)
  "Make PANE the active pane of WINDOW.
   Records the previously active pane in window-last-active and updates
   window-last-active-time."
  (let ((current (window-active window)))
    (when (and current (not (eq current pane)))
      (setf (window-last-active window) current)))
  (setf (window-active window) pane
        (window-last-active-time window) (get-universal-time)))

;;; ── Orientation-aware pane extent ──────────────────────────────────────────
;;;
;;; The :v/:h naming matches layout.lisp's split-tree orientation keywords:
;;;   :v split stacks children vertically → extent measured in ROWS (height)
;;;   :h split places children side-by-side → extent measured in COLS (width)
;;;
;;; Axis fact table (Prolog-style):
;;;   axis_extent(:v, pane) :- pane-height.
;;;   axis_extent(:h, pane) :- pane-width.

(defun %orient-pane-extent (pane orient)
  "Current extent of PANE along ORIENT's split axis."
  (orient-case orient :v (pane-height pane) :h (pane-width pane)))

(defun %split-axis-fits-p (extent orient)
  "T when EXTENT is large enough to split along ORIENT.
   Requires at least 2 * axis-floor + +pane-separator-width+ cells."
  (let ((axis-floor (%axis-floor orient)))
    (>= extent (+ axis-floor +pane-separator-width+ axis-floor))))

(defun %split-fits-p (pane orient)
  "T when PANE is wide/tall enough to split along ORIENT."
  (%split-axis-fits-p (%orient-pane-extent pane orient) orient))

;;; ── Window-level pane ID allocation ────────────────────────────────────────

(defun next-pane-id (window)
  "Smallest pane id >= +PANE-BASE-INDEX+ not already used in WINDOW.
   Window-level concern: queries pane membership, not geometry."
  (let ((used (mapcar #'pane-id (window-panes window))))
    (loop for i from +pane-base-index+
          unless (member i used) return i)))

;;; ── Size-hint conversion ────────────────────────────────────────────────────
;;;
;;; Size-hint fact table (Prolog-style):
;;;   hint_rule(integer, positive) :- hint cells for the new pane.
;;;   hint_rule(real, 0<r<1)       :- proportional cells derived from avail.
;;;   hint_rule(_default_)         :- half the available space.

(defun %requested-cells-from-hint (hint avail orient)
  "Convert a split size HINT to a cell count within AVAIL along ORIENT.
   Returns an integer: the requested cell count for the new (second) child."
  (declare (ignorable orient))
  (typecase hint
    (integer (if (> hint 0) hint (floor avail 2)))
    (real    (if (< 0.0 hint 1.0) (round (* avail hint)) (floor avail 2)))
    (t       (floor avail 2))))

(defun %ratio-from-size-hint (hint avail orient)
  "Convert a size HINT (integer cells or real percentage) to a split ratio for
   the new (second) child given AVAIL total cells and ORIENT.
   Returns a ratio in (0,1) clamped to leave at least the axis floor on each side."
  (let* ((axis-floor   (%axis-floor orient))
         ;; Requested cells for the NEW (second) child.
         (requested    (%requested-cells-from-hint hint avail orient))
         ;; Upper bound: leave at least axis-floor cells for the FIRST child.
         (upper-bound  (- avail axis-floor))
         ;; Clamped size: both halves stay above axis-floor.
         (clamped-size (max axis-floor (min upper-bound requested))))
    (/ clamped-size avail)))

(defun %split-fit-p (window active direction full)
  "T when a split along DIRECTION would fit: a full split (FULL T) is measured
   against WINDOW's own extent; a normal split is measured against ACTIVE pane's
   extent."
  (if full
      (%split-axis-fits-p (%window-axis-extent window direction) direction)
      (%split-fits-p active direction)))

(defun %new-split-pane (session window direction active spec)
  "Construct the new pane created by a split of ACTIVE along DIRECTION.
   Returns the new pane, either PTY-backed (via %fork-pane) or, when SPEC's
   INPUT-ONLY is T, a screen-only pane with a blank screen (later fed via
   pane-feed)."
  (multiple-value-bind (px py pw ph) (split-child-geometry active direction)
    (if (%split-spec-input-only spec)
        (%make-input-pane (next-pane-id window) px py pw ph)
        (%fork-pane session (next-pane-id window) px py pw ph
                    :start-dir (%split-spec-start-dir spec)))))

(defun %split-ratio (window active direction spec)
  "Return the split ratio for the new (second) child of a split along DIRECTION.
   AVAIL is the whole window extent for a full split, else the active pane's
   extent; SPEC's SIZE is the caller's size hint (or NIL for an even 1/2 split)."
  (let ((avail (1- (if (%split-spec-full spec)
                       (%window-axis-extent window direction)
                       (%orient-pane-extent active direction))))
        (size  (%split-spec-size spec)))
    (if size
        (%ratio-from-size-hint size avail direction)
        1/2)))

(defun %compute-new-pane-split (session window direction leaf active spec)
  "Build the new pane and its layout-split node for a window-split per SPEC.
   ANCHOR is the existing node that becomes the new pane's sibling: the whole
   tree for a full split, else just the active pane's LEAF.  SPEC's BEFORE T
   inserts the new pane as the first child, existing as second; otherwise the
   reverse.  Returns (values new-pane split-node)."
  (let* ((new-pane  (%new-split-pane session window direction active spec))
         (new-ratio (%split-ratio window active direction spec))
         (anchor    (if (%split-spec-full spec) (window-tree window) leaf))
         (split     (if (%split-spec-before spec)
                        (make-layout-split direction
                                           (make-layout-leaf new-pane)
                                           anchor
                                           new-ratio)
                        (make-layout-split direction anchor
                                           (make-layout-leaf new-pane)
                                           (- 1 new-ratio)))))
    (when (%split-spec-input-bytes spec)
      (pane-feed new-pane (%split-spec-input-bytes spec)))
    (values new-pane split)))

(defun %splice-split-into-tree (window leaf split spec)
  "Splice SPLIT into WINDOW's tree, replacing LEAF (normal split) or becoming
   the new tree root (SPEC's FULL split)."
  (if (%split-spec-full spec)
      (setf (window-tree window) split)
      (%replace-in-tree window leaf split)))

(defun window-split (session window direction
                     &key no-focus size start-dir before full input-only input-bytes)
  "Split the active pane of WINDOW along DIRECTION (:h left/right, :v top/bottom).
   Returns the new pane, or NIL when the active pane is too small.
   NO-FOCUS T keeps the current active pane selected (the new pane is created
   but not focused).  SIZE is an integer (cells) or real (fraction 0..1) that
   controls the new pane's initial size along the split axis.
   BEFORE T inserts the new pane before (left of / above) the active pane
   instead of after (right of / below) — matches split-window -b.
   FULL T makes the new pane span the FULL window dimension (split-window -f): the
   split is inserted at the tree ROOT, with the entire existing layout as one child
   and the new pane as the other, instead of subdividing only the active pane.
   INPUT-ONLY T creates a pane without a PTY and feeds INPUT-BYTES into its screen.
   START-DIR: when non-NIL, the new pane's shell starts in that directory."
  (let ((active (window-active-pane window))
        (tree   (window-tree window))
        (spec   (%make-split-spec :no-focus no-focus :size size :start-dir start-dir
                                  :before before :full full :input-only input-only
                                  :input-bytes input-bytes)))
    (when (and active tree)
      (let ((leaf (layout-find-leaf tree active)))
        (when (and leaf (%split-fit-p window active direction full))
          (multiple-value-bind (new-pane split)
              (%compute-new-pane-split session window direction leaf active spec)
            (%splice-split-into-tree window leaf split spec)
            (setf (pane-window new-pane) window)
            (window-relayout-current window)
            (unless no-focus
              (setf (window-active window) new-pane))
            new-pane))))))

;;; Tree-link mutation, relayout, and removal moved to window-tree.lisp.

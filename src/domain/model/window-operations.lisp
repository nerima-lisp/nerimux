(in-package #:nerimux/model)

;;; ── Window resize and zoom operations ─────────────────────────────────────────
;;;
;;; This file holds the window-resize-active and window-zoom-toggle operations
;;; split from window-core.lisp/window-tree.lisp.  All functions depend on:
;;;   - window struct accessors (window-definitions.lisp)
;;;   - layout helpers: layout-find-leaf, layout-find-parent, layout-split-*,
;;;     resize-find-split, resize-direction-orientation, layout-leaves (layout.lisp)
;;;   - %axis-floor (layout.lisp), +pane-separator-width+ (window-definitions.lisp)
;;;   - pane-reposition (pane-geometry.lisp)
;;;
;;; Data/logic separation:
;;;   %zoom-in-geometry / %zoom-out-geometry — pure tree-slot mutations (no I/O)
;;;   window-zoom-toggle                     — orchestrator: tree mutation + PTY resize

;;; ── Resize via the tree ──────────────────────────────────────────────────────

(defun %new-split-ratio (orient avail cur-ratio delta grow-first)
  "Compute the ratio after moving the split border by DELTA cells.
   Returns the new ratio as a rational, or NIL when the move would violate
   the minimum pane size on either side."
  (let* ((axis-floor (%axis-floor orient))
         (cur-first  (round (* avail cur-ratio)))
         (sign       (if grow-first 1 -1))
         (new-first  (+ cur-first (* sign delta))))
    (when (and (<= axis-floor new-first) (<= new-first (- avail axis-floor)))
      (/ new-first avail))))

(defun %grow-first-p (side direction)
  "Return T when the first child of a split should grow given SIDE (:first/:second)
   and the resize DIRECTION (:left/:right/:up/:down)."
  (if (eq side :first)
      (member direction '(:right :down))
      (member direction '(:left :up))))

(defun window-resize-active (window direction delta)
  "Move the split border between the active pane and its neighbour in DIRECTION
   by DELTA cells, then relayout.  Returns the active pane on success, NIL when
   there is no neighbour in DIRECTION or the move would violate the minimum pane size."
  (let* ((tree   (window-tree window))
         (active (window-active-pane window))
         (orient (resize-direction-orientation direction)))
    (when (and tree active)
      (let ((leaf (layout-find-leaf tree active)))
        (when leaf
          (multiple-value-bind (split side) (resize-find-split tree leaf orient)
            (when split
              (let* ((avail      (max +pane-separator-width+
                                      (- (layout-split-axis-extent split orient)
                                         +pane-separator-width+)))
                     (grow-first (%grow-first-p side direction))
                     (new-ratio  (%new-split-ratio orient avail
                                                   (layout-split-ratio split)
                                                   delta grow-first)))
                (when new-ratio
                  (setf (layout-split-ratio split) new-ratio)
                  (window-relayout-current window)
                  active)))))))))

;;; ── Zoom helpers — pure tree transforms ─────────────────────────────────────
;;;
;;; Data/logic separation: the pure tree-slot mutations (%zoom-in-geometry,
;;; %zoom-out-geometry) are isolated from the PTY resize side-effect
;;; (pane-reposition in window-zoom-toggle) so each concern is a named step.

(defun %zoom-in-geometry (window pane)
  "Save the current tree and replace it with a single-leaf tree for PANE.
   Sets window-zoom-p to T and refreshes the panes list.
   Does NOT call pane-reposition — the caller handles the PTY resize."
  (setf (window-zoom-tree window) (window-tree window)
        (window-tree       window) (make-layout-leaf pane)
        (window-zoom-p     window) t)
  (window-refresh-panes window))

(defun %zoom-out-geometry (window)
  "Restore the saved tree from window-zoom-tree and clear zoom flags.
   Guards against corrupted state where zoom-tree is NIL.
   Returns T on success, NIL when the saved tree was missing."
  (when (window-zoom-tree window)
    (setf (window-tree      window) (window-zoom-tree window)
          (window-zoom-tree window) nil
          (window-zoom-p    window) nil)
    (window-relayout window (window-height window) (window-width window))
    t))

(defun window-zoom-toggle (window)
  "Toggle zoom on WINDOW's active pane.
   Zooming in saves the current tree, replaces it with a single-leaf tree, then
   calls pane-reposition to give the pane the full window rectangle.
   Zooming out restores the saved tree and relayouts canonically.
   All slot mutations are protected by the window lock to prevent renderer races."
  (with-lock-held ((window-lock window))
    (if (window-zoom-p window)
        ;; Zoom out: restore saved tree (guard against corrupted state).
        (%zoom-out-geometry window)
        ;; Zoom in: save tree, replace with single leaf, then resize PTY.
        (let ((pane (window-active-pane window)))
          (when pane
            (%zoom-in-geometry window pane)
            (pane-reposition pane 0 0 (window-width window) (window-height window)))))))

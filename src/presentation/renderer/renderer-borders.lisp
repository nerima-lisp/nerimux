(in-package #:nerimux/renderer)

;;;; Split-tree separator and pane border rendering.

;;; ── Split-tree separators ───────────────────────────────────────────────────

(defun layout-subtree-rect (node)
  "Bounding rectangle of NODE's leaves as a plist (:x :y :w :h), derived from the
   already-laid-out pane geometry."
  (multiple-value-bind (min-x min-y width height) (layout-node-bounding-box node)
    (list :x min-x :y min-y :w width :h height)))

(defun subtree-contains-p (node pane)
  "True when PANE is a leaf of NODE's subtree."
  (and pane (member pane (layout-leaves node))))

;;; ── Border style SGR / glyphs ────────────────────────────────────────────────
;;;
;;; §1.4/R6.6 fix every pane-border option: pane-border-lines is always
;;; "single" (so the double/heavy/simple/padded/number glyph table and the
;;; number-drawing code that only "number" ever reached are unreachable —
;;; deleted, not hardcoded to a dead branch); pane-border-indicators is
;;; always "colour" (so the arrows/both glyph code, only reachable for
;;; "arrows"/"both", is equally unreachable — deleted); pane-active-border-
;;; style is always "fg=green" (SGR "32", what %color-name-to-sgr-number
;;; used to resolve "green" to) and pane-border-style (inactive) is always ""
;;; (no colour — a plain reset).  pane-border-status/pane-border-format are
;;; deleted outright per R6.6: no label is ever drawn on a border.

(defconstant +pane-border-vertical+ #\│
  "Vertical pane-border glyph.  pane-border-lines is fixed \"single\" (§1.4);
   this was already single-line box-drawing's fallback value for any
   style other than double/heavy/simple/padded.")
(defconstant +pane-border-horizontal+ #\─
  "Horizontal pane-border glyph; see +pane-border-vertical+.")
(defconstant +sgr-active-border+ "32"
  "SGR for the active pane's border: pane-active-border-style's fixed value
   \"fg=green\" (foreground green, SGR 32).")

(defun %render-h-separator (stream node active-pane terminal-cols)
  "Draw the vertical column between the left and right children of an :h split.
   Coloured green when it borders the active pane, otherwise left at the
   terminal's default colour."
  (let* ((a          (layout-split-first  node))
         (b          (layout-split-second node))
         (rect       (layout-subtree-rect a))
         (border-col (+ (getf rect :x) (getf rect :w)))
         (activep    (or (subtree-contains-p a active-pane)
                         (subtree-contains-p b active-pane))))
    (when (< border-col terminal-cols)
      (reset-attrs stream)
      (when activep (%emit-sgr stream +sgr-active-border+))
      (let ((top    (getf rect :y))
            (height (getf rect :h)))
        (loop for row from top below (+ top height)
              do (move-to stream row border-col)
                 (write-char +pane-border-vertical+ stream)))
      (reset-attrs stream))))

(defun %render-v-separator (stream node active-pane terminal-cols)
  "Draw the horizontal row between the top and bottom children of a :v split."
  (declare (ignore active-pane))
  (let* ((a    (layout-split-first  node))
         (rect (layout-subtree-rect a))
         (border-row (+ (getf rect :y) (getf rect :h)))
         (x          (getf rect :x))
         (w          (min (getf rect :w) (- terminal-cols x))))
    (reset-attrs stream)
    (move-to stream border-row x)
    (loop repeat (max 0 w) do (write-char +pane-border-horizontal+ stream))))

;;; ── Tree border walk (logic layer) ──────────────────────────────────────────

(defun render-tree-borders (stream node active-pane terminal-cols)
  "Walk the split-tree NODE, drawing one separator per internal split node.
   :h (left|right) splits draw │ bars; :v (top/bottom) splits draw ─ bars.
   Recurses into both children after drawing the parent separator."
  (when (layout-split-p node)
    (ecase (layout-split-orientation node)
      (:h (%render-h-separator stream node active-pane terminal-cols))
      (:v (%render-v-separator stream node active-pane terminal-cols)))
    (render-tree-borders stream (layout-split-first  node) active-pane terminal-cols)
    (render-tree-borders stream (layout-split-second node) active-pane terminal-cols)))

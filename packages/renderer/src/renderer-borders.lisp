(in-package #:nerimux/renderer)

(defun layout-subtree-rect (node)
  "Bounding rectangle of NODE's leaves as a plist (:x :y :w :h), derived from the
   already-laid-out pane geometry."
  (multiple-value-bind (min-x min-y width height) 
      (layout-node-bounding-box node)
    (list :x min-x :y min-y :w width :h height)))

(defun subtree-contains-p (node pane)
  "True when PANE is a leaf of NODE's subtree."
  (and pane (member pane (layout-leaves node))))

(defconstant +pane-border-vertical+
  #\│
  "Vertical pane-border glyph.  pane-border-lines is fixed \"single\" (§1.4);
   this was already single-line box-drawing's fallback value for any
   style other than double/heavy/simple/padded.")

(defconstant +pane-border-horizontal+
  #\─
  "Horizontal pane-border glyph; see +pane-border-vertical+.")

(defconstant +sgr-active-border+
  (if (boundp (quote +sgr-active-border+))
      (symbol-value (quote +sgr-active-border+))
      +sgr-accent+)
  "SGR for a separator that borders the active pane: the theme accent.
   Replaces the pre-theme fixed \"fg=green\" (SGR 32).")

(defun %split-touches-active-p (node active-pane)
  "True when either child of split NODE contains ACTIVE-PANE."
  (or (subtree-contains-p (layout-split-first node) active-pane)
      (subtree-contains-p (layout-split-second node) active-pane)))

(defun %render-h-separator (stream node active-pane terminal-cols)
  "Draw the vertical column between the left and right children of an :h split.
   Accent-coloured when it borders the active pane, otherwise a faint gray
   (+SGR-LINE+) so inactive structure recedes."
  (let* ((a (layout-split-first node))
         (rect (layout-subtree-rect a))
         (border-col (+ (getf rect :x) (getf rect :w)))
         (activep (%split-touches-active-p node active-pane)))
    (when (< border-col terminal-cols)
      (reset-attrs stream)
      (%emit-sgr stream
                 (if activep
                     +sgr-active-border+
                     +sgr-line+))
      (let ((top (getf rect :y))
            (height (getf rect :h)))
        (loop for row from top below (+ top height)
              do (move-to stream row border-col) (write-char
                                                  +pane-border-vertical+
                                                  stream)))
      (reset-attrs stream))))

(defun %render-v-separator (stream node active-pane terminal-cols)
  "Draw the horizontal row between the top and bottom children of a :v split,
   with the same active-accent/inactive-faint colouring as the vertical bars
   (the pre-theme version left every horizontal bar uncoloured)."
  (let* ((a (layout-split-first node))
         (rect (layout-subtree-rect a))
         (border-row (+ (getf rect :y) (getf rect :h)))
         (x (getf rect :x))
         (w (min (getf rect :w) (- terminal-cols x)))
         (activep (%split-touches-active-p node active-pane)))
    (reset-attrs stream)
    (%emit-sgr stream
               (if activep
                   +sgr-active-border+
                   +sgr-line+))
    (move-to stream border-row x)
    (loop repeat (max 0 w)
          do (write-char +pane-border-horizontal+ stream))
    (reset-attrs stream)))

(defun render-tree-borders (stream node active-pane terminal-cols)
  "Walk the split-tree NODE, drawing one separator per internal split node.
   :h (left|right) splits draw │ bars; :v (top/bottom) splits draw ─ bars.
   Recurses into both children after drawing the parent separator."
  (when (layout-split-p node)
    (ecase (layout-split-orientation node)
      (:h (%render-h-separator stream node active-pane terminal-cols))
      (:v (%render-v-separator stream node active-pane terminal-cols)))
    (render-tree-borders stream
                         (layout-split-first node)
                         active-pane
                         terminal-cols)
    (render-tree-borders stream
                         (layout-split-second node)
                         active-pane
                         terminal-cols)))

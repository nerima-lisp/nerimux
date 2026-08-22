(in-package #:nerimux/test)

;;;; Pane and border rendering tests.
;;;;
;;;; Covers: render-pane, layout-subtree-rect, subtree-contains-p,
;;;;         render-tree-borders from src/presentation/renderer/renderer-pane.lisp
;;;;         and renderer-borders.lisp.
;;;;
;;;; renderer-suite is declared in renderer-format-tests.lisp (loaded first).
;;;;
;;;; §1.4/R6.6 fixed every pane-border and window-style option at its
;;;; registered default: pane-border-lines is always "single" (the
;;;; double/heavy/simple/padded/number glyph dispatch is gone —
;;;; +pane-border-vertical+/+pane-border-horizontal+ are now fixed
;;;; constants), pane-border-indicators is always "colour" (the arrows/off
;;;; dispatch is gone — the active pane's border is always coloured),
;;;; pane-border-status/pane-border-format are deleted outright (no label is
;;;; ever drawn on a border), and window-style/window-active-style are
;;;; always "" (a pane's default-bg cells are never recoloured) — see
;;;; renderer-borders.lisp and renderer-pane.lisp.

;;; -- Local fixture ----------------------------------------------------------
;;;
;;; make-renderer-test-session (defined in t/helpers-renderer-fixtures.lisp) is the canonical
;;; shared fixture.  The old local %make-pane-test-session has been removed in
;;; favour of the shared version.

(defun %snippet-around (text needle &optional (radius 24))
  (let ((pos (position needle text)))
    (and pos
         (subseq text pos (min (length text) (+ pos radius))))))

(describe "renderer-suite"

  ;; -- render-pane (content + positioning) ------------------------------------

  ;; render-pane emits the pane's cell glyphs preceded by a cursor-position sequence for row 0.
  (it "render-pane-content-and-positioning"
    (let* ((sess (make-renderer-test-session 5 2 :content "hi"))
           (pane (first (window-panes (session-active-window sess))))
           (out  (render-pane-output sess pane)))
      (expect (find #\h out))
      (expect (find #\i out))
      (expect (search (format nil "~C[1;1H" #\Escape) out))))

  ;; With DECSCNM (reverse-screen) on, render-pane emits the reverse attribute (SGR 7)
  ;; globally; the rendered output differs from the non-reversed render.
  (it "render-pane-decscnm-reverses-output"
    (let* ((sess   (make-renderer-test-session 2 1))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-cell screen 0 0)
            (nerimux/terminal/types:make-cell :char #\A))
      (setf (nerimux/terminal/types:screen-reverse-screen screen) nil)
      (let ((normal (render-pane-output sess pane)))
        (setf (nerimux/terminal/types:screen-reverse-screen screen) t)
        (let ((reversed (render-pane-output sess pane)))
          (let ((normal-snippet (%snippet-around normal #\A))
                (reversed-snippet (%snippet-around reversed #\A)))
            (expect (not (string= normal reversed)))
            (expect (and reversed-snippet (search ";7" reversed-snippet)))
            (expect (and normal-snippet (null (search ";7" normal-snippet)))))))))

  ;; -- double-width glyphs are not double-printed ------------------------------

  ;; A double-width glyph occupying two cells is printed exactly once, not twice.
  (it "render-pane-double-width-not-duplicated"
    (let* ((sess   (make-renderer-test-session 5 2))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (nerimux/test::utf8-feed screen "あ")
      (let ((out (render-pane-output sess pane)))
        (expect (= 1 (count #\あ out))))))

  ;; -- OSC 8 hyperlinks re-emitted around their cell span ----------------------

  ;; A cell written under OSC 8 is re-emitted with its hyperlink (set before the
  ;; cell, cleared after) so the outer terminal makes it clickable.
  (it "render-pane-emits-osc-8-hyperlink"
    (let* ((sess   (make-renderer-test-session 10 2))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (feed screen (format nil "~C]8;;https://x~C\\X" #\Escape #\Escape))
      (let ((out (render-pane-output sess pane)))
        (expect (search (format nil "~C]8;;https://x~C\\" #\Escape #\Escape) out))
        (expect (search (format nil "~C]8;;~C\\" #\Escape #\Escape) out)))))

  ;; Plain content (no OSC 8) emits no OSC 8 sequence — existing render output is
  ;; unchanged for the common no-hyperlink case.
  (it "render-pane-no-osc-8-without-hyperlink"
    (let* ((sess   (make-renderer-test-session 10 2))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (feed screen "plain")
      (let ((out (render-pane-output sess pane)))
        (expect (null (search (format nil "~C]8;" #\Escape) out))))))

  ;; -- %pane-cell-base-colors (window-style is fixed off; see file header) -----

  ;; %pane-cell-base-colors only substitutes the pane defaults: an explicit
  ;; non-default background survives unchanged.
  (it "pane-cell-base-colors-preserves-explicit-background"
    (let ((cell (nerimux/terminal/types:make-cell :char #\X :fg nerimux/terminal/types:+default-color+ :bg 200)))
      (multiple-value-bind (fg bg)
          (nerimux/renderer::%pane-cell-base-colors cell 31 52)
        (expect (= 31 fg))
        (expect (= 200 bg)))))

  ;; %pane-cell-base-colors substitutes the pane defaults ONLY for cells whose
  ;; colour is the +default-color+ sentinel; explicit white(7)/black(0) survive.
  (it "pane-cell-base-colors-recolours-only-default-sentinel"
    ;; Default-sentinel cell: both fg and bg get the pane defaults.
    (let ((cell (nerimux/terminal/types:make-cell
                 :char #\X
                 :fg nerimux/terminal/types:+default-color+
                 :bg nerimux/terminal/types:+default-color+)))
      (multiple-value-bind (fg bg)
          (nerimux/renderer::%pane-cell-base-colors cell 31 52)
        (expect (= 31 fg))
        (expect (= 52 bg))))
    ;; Explicit white(7)/black(0): NOT recoloured (this is the gap fix).
    (let ((cell (nerimux/terminal/types:make-cell :char #\X :fg 7 :bg 0)))
      (multiple-value-bind (fg bg)
          (nerimux/renderer::%pane-cell-base-colors cell 31 52)
        (expect (= 7 fg))
        (expect (= 0 bg)))))

  ;; %resolve-pane-style-colours always resolves DEF-FG/DEF-BG to NIL — there
  ;; is no config to set window-style/window-active-style away from "" — so a
  ;; pane's default-bg cells are never recoloured (§1.4).
  (it "resolve-pane-style-colours-never-recolours-defaults"
    (let* ((sess (make-renderer-test-session 5 2 :content "hi"))
           (pane (first (window-panes (session-active-window sess))))
           (colours (nerimux/renderer::%resolve-pane-style-colours pane)))
      (expect (null (nerimux/renderer::pane-style-def-fg colours)))
      (expect (null (nerimux/renderer::pane-style-def-bg colours)))))

  ;; -- layout-subtree-rect and subtree-contains-p ------------------------------

  ;; layout-subtree-rect returns the tight bounding box of all leaves.
  (it "layout-subtree-rect-bounding-box"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/model::layout-assign tree 0 0 81 24)
      (let ((rect (nerimux/renderer::layout-subtree-rect tree)))
        (expect (= 0  (getf rect :x)))
        (expect (= 0  (getf rect :y)))
        (expect (= 81 (getf rect :w)))
        (expect (= 24 (getf rect :h))))))

  ;; subtree-contains-p returns T for panes in the subtree and NIL otherwise.
  (it "subtree-contains-p-detects-membership"
    (let* ((l0 (tl-leaf 1 1 1))
           (l1 (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (p0  (layout-leaf-pane l0))
           (p1  (layout-leaf-pane l1))
           (p-other (make-pane :id 99 :fd -1 :pid -1 :screen (make-screen 1 1))))
      (expect (nerimux/renderer::subtree-contains-p tree p0) :to-be-truthy)
      (expect (nerimux/renderer::subtree-contains-p tree p1) :to-be-truthy)
      (expect (nerimux/renderer::subtree-contains-p tree p-other) :to-be-falsy)
      (expect (nerimux/renderer::subtree-contains-p tree nil) :to-be-falsy)))

  ;; -- render-tree-borders -----------------------------------------------------

  ;; render-tree-borders draws vertical-bar separators for a :h split.
  (it "render-tree-borders-draws-vertical-bar"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/model::layout-assign tree 0 0 81 24)
      (let ((out (render-tree-borders-output tree (layout-leaf-pane l0) 81)))
        (expect (plusp (length out)))
        (expect (find #\│ out)))))

  ;; The active pane's border is always coloured green (SGR 32) —
  ;; pane-active-border-style's fixed value — and a border that touches no
  ;; active pane carries no colour.
  (it "render-tree-borders-active-pane-always-coloured"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/model::layout-assign tree 0 0 81 24)
      (expect (search (format nil "~C[32m" #\Escape)
                      (render-tree-borders-output tree (layout-leaf-pane l0) 81)))
      (expect (null (search (format nil "~C[32m" #\Escape)
                            (render-tree-borders-output tree nil 81)))))))

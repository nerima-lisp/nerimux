(in-package #:nerimux/renderer)

;;;; Pane and border rendering.
;;;;
;;;; Depends on the ANSI escape-code primitives from renderer-format.lisp
;;;; (loaded first in the same package) and the layout/model structures from
;;;; nerimux/model.

;;; ── Per-row cell rendering ───────────────────────────────────────────────────

(defstruct (sgr-register (:conc-name sgr-reg-))
  "Mutable SGR state registers threaded across cells (and rows for hyperlinks).
   Tracks the last-emitted attribute values so redundant SGR sequences are suppressed."
  (fg        -1  :type fixnum)
  (bg        -1  :type fixnum)
  (attrs     -1  :type fixnum)
  (attrs2    -1  :type fixnum)
  (ul-color  -1  :type fixnum)
  (hyperlink nil))

(defun %pane-cell-in-selection-p (row col sel-active sel-start-row sel-end-row
                                  sel-start-col sel-end-col sel-rect-p)
  "True when cell (ROW, COL) falls inside the active copy-mode selection.
   Always false when SEL-ACTIVE is NIL."
  (and sel-active
       (in-selection-p row col sel-start-row sel-end-row
                       sel-start-col sel-end-col sel-rect-p)))

(defun %emit-cell-sgr-if-changed (stream sgr-reg fg bg attrs attrs2 ul-color)
  "Emit an SGR sequence for FG/BG/ATTRS/ATTRS2/UL-COLOR to STREAM, but only when
   they differ from the last-emitted values recorded in SGR-REG.  Updates SGR-REG
   to the new values as a side-effect.  Suppressing redundant SGR sequences keeps
   the per-frame output small when neighbouring cells share the same style."
  (unless (and (= fg       (sgr-reg-fg       sgr-reg))
               (= bg       (sgr-reg-bg       sgr-reg))
               (= attrs    (sgr-reg-attrs    sgr-reg))
               (= attrs2   (sgr-reg-attrs2   sgr-reg))
               (= ul-color (sgr-reg-ul-color sgr-reg)))
    (render-cell-attrs stream fg bg attrs attrs2 ul-color)
    (setf (sgr-reg-fg       sgr-reg) fg
          (sgr-reg-bg       sgr-reg) bg
          (sgr-reg-attrs    sgr-reg) attrs
          (sgr-reg-attrs2   sgr-reg) attrs2
          (sgr-reg-ul-color sgr-reg) ul-color)))

(defun %emit-cell-hyperlink-if-changed (stream sgr-reg hyperlink)
  "Emit an OSC 8 hyperlink-start/stop escape to STREAM when HYPERLINK differs
   from the link recorded in SGR-REG (entering, leaving, or switching a link
   span).  Updates SGR-REG to the new value as a side-effect."
  (unless (equal hyperlink (sgr-reg-hyperlink sgr-reg))
    (write-string (format nil "~C]8;;~@[~A~]~C\\" #\Escape hyperlink #\Escape) stream)
    (setf (sgr-reg-hyperlink sgr-reg) hyperlink)))

(defstruct (selection-bounds (:conc-name sel-bounds-))
  "Normalised copy-mode selection boundary for one rendered frame, bundled so the
   per-cell renderers take a single value instead of eight positional arguments.
   Built once per frame from %compute-selection-bounds's eight return values
   (which its direct unit tests still consume positionally)."
  active start-row end-row start-col end-col rect-p mark-row mark-col)

(defun %render-cell (stream cell row col sgr-reg rev-screen
                     def-fg def-bg selection-style-fg selection-style-bg
                     mark-style-fg mark-style-bg sel)
  "Resolve CELL's colours through the base → mark → selection → attrs pipeline
   and render it to STREAM, threading the last-emitted SGR state through SGR-REG.
   SEL is the frame's SELECTION-BOUNDS."
  (let* ((in-sel (%pane-cell-in-selection-p row col
                                            (sel-bounds-active sel)
                                            (sel-bounds-start-row sel) (sel-bounds-end-row sel)
                                            (sel-bounds-start-col sel) (sel-bounds-end-col sel)
                                            (sel-bounds-rect-p sel))))
    (multiple-value-bind (base-fg base-bg) (%pane-cell-base-colors cell def-fg def-bg)
      (multiple-value-bind (mark-col-p mark-fg mark-bg)
          (%pane-cell-mark-colors row col
                                  (sel-bounds-mark-row sel) (sel-bounds-mark-col sel)
                                  mark-style-fg mark-style-bg base-fg base-bg)
        (multiple-value-bind (sel-fg sel-bg selection-style-colour)
            (%pane-cell-selection-colors in-sel selection-style-fg selection-style-bg
                                         base-fg base-bg)
          (let* ((fg (if mark-col-p mark-fg sel-fg))
                 (bg (if mark-col-p mark-bg sel-bg))
                 ;; DECSCNM (reverse-video screen) and the selection highlight both
                 ;; toggle reverse; XOR both so a cell that is reverse for two
                 ;; reasons renders normal (correct double-reverse).
                 (attrs (%pane-cell-attrs cell in-sel selection-style-colour mark-col-p rev-screen))
                 ;; Extended attributes and underline colour pass through without
                 ;; modification (no selection / DECSCNM involvement).
                 (attrs2   (cell-attrs2 cell))
                 (ul-color (cell-ul-color cell)))
            (%emit-cell-sgr-if-changed stream sgr-reg fg bg attrs attrs2 ul-color)
            (%emit-cell-hyperlink-if-changed stream sgr-reg (cell-hyperlink cell))
            (write-char (cell-char cell) stream)
            ;; Unicode combining characters (zero-width marks) follow the base char.
            (dolist (ch (cell-combining cell))
              (write-char ch stream))))))))

(defun %render-cell-row (stream screen pane-col-count row
                         sel
                         sgr-reg
                         def-fg def-bg selection-style-fg selection-style-bg
                         mark-style-fg mark-style-bg
                         &optional viewport)
  "Render one row of cells to STREAM, highlighting selected cells.
   SEL is the frame's SELECTION-BOUNDS, forwarded to each cell.
   SGR-REG is a sgr-register struct used as mutable state across rows (last-emitted
   fg/bg/attrs/ul-color/hyperlink); the caller initialises it once and threads it
   across all rows in the pane.
   DEF-FG / DEF-BG (or NIL) are the pane's window-style default colours.
   SELECTION-STYLE-FG / SELECTION-STYLE-BG (or NIL) are the copy-mode selection
   colours.
   MARK-STYLE-FG / MARK-STYLE-BG (or NIL) are the copy-mode mark-row colours.
  Returns nothing; mutates SGR-REG as a side-effect."
  ;; DECDHL/DECDWL: re-emit the row's line-size attribute so the OUTER
  ;; terminal draws double-width/height lines.  Only active when any row
  ;; carries a size flag; unflagged rows then emit single-width (ESC # 5)
  ;; to reset a previously-flagged terminal line.
  (let ((sizes (nerimux/terminal/types:screen-line-sizes screen)))
    (when (plusp (hash-table-count sizes))
      (format stream "~C#~C" #\Escape (or (gethash row sizes) #\5))))
  (loop with rev-screen = (and (screen-reverse-screen screen)
                               nerimux/terminal/types:+attr-reverse+)
        for col below pane-col-count
        for cell = (screen-display-cell screen col row viewport)
        ;; A continuation cell (width 0) is the right half of a double-width
        ;; glyph the terminal already drew — emit nothing.
        unless (zerop (cell-width cell))
          do (%render-cell stream cell row col sgr-reg rev-screen
                           def-fg def-bg selection-style-fg selection-style-bg
                           mark-style-fg mark-style-bg sel)))

(defun %pane-cell-base-colors (cell def-fg def-bg)
  "Substitute the pane's window-style default colours DEF-FG / DEF-BG only for
   cells whose colour is the terminal-default sentinel (+default-color+).  Cells
   carrying an explicit palette index (including 7=white / 0=black) or true-colour
   are left untouched -- only cells still carrying the terminal-default sentinel
   are eligible for window-style recolour."
  (let ((raw-fg (cell-fg cell))
        (raw-bg (cell-bg cell)))
    (values (if (and def-fg (= raw-fg nerimux/terminal/types:+default-color+)) def-fg raw-fg)
            (if (and def-bg (= raw-bg nerimux/terminal/types:+default-color+)) def-bg raw-bg))))

(defun %pane-cell-mark-colors (row col sel-mark-row sel-mark-col
                               mark-style-fg mark-style-bg
                               base-fg base-bg)
  (let* ((mark-row-p (and sel-mark-row (= row sel-mark-row)))
         (mark-col-p (and mark-row-p sel-mark-col (= col sel-mark-col)))
         (mark-style-active (and mark-row-p (or mark-style-fg mark-style-bg)))
         (mark-fg (if mark-style-active (or mark-style-fg base-fg) base-fg))
         (mark-bg (if mark-style-active (or mark-style-bg base-bg) base-bg)))
    (values mark-col-p mark-fg mark-bg)))

(defun %pane-cell-selection-colors (in-sel selection-style-fg selection-style-bg
                                    base-fg base-bg)
  (let ((selection-style-colour (and in-sel
                                     (or selection-style-fg selection-style-bg))))
    (values (if selection-style-colour
                (or selection-style-fg base-fg)
                base-fg)
            (if selection-style-colour
                (or selection-style-bg base-bg)
                base-bg)
            selection-style-colour)))

(defun %pane-cell-attrs (cell in-sel selection-style-colour mark-col-p rev-screen)
  (let ((attrs (logxor (cell-attrs cell)
                       (if (and in-sel (not selection-style-colour) (not mark-col-p))
                           nerimux/terminal/types:+attr-reverse+ 0)
                       (or rev-screen 0))))
    (if mark-col-p
        (logior attrs nerimux/terminal/types:+attr-reverse+)
        attrs)))

(defstruct (pane-style-colours (:conc-name pane-style-))
  "Resolved fg/bg cell-colour numbers (each NIL or a cell-colour integer)
   consumed by %render-pane-body, bundled so render-pane can pass them around
   as one value instead of six."
  def-fg def-bg
  selection-fg selection-bg
  mark-fg mark-bg)

;;; window-style / window-active-style (the pane-background recolour hook)
;;; defaulted to "" — no override — and nothing could ever set them once
;;; domain/options (R2.2) has no config or set-option to write through, so
;;; DEF-FG/DEF-BG below are always NIL: %pane-cell-base-colors never
;;; recolours a cell.  copy-mode-mark-style (§1.4: mark the selection anchor
;;; row) is the one style here that ever resolved to real colours — its
;;; default "bg=red,fg=black" parsed via the old %color-name-to-cell-color
;;; table to cell colours 1 (red) / 0 (black); those two integers are now
;;; hardcoded instead of re-derived from the string every frame.
;;;
;;; copy-mode-selection-style (§1.4/R6.8: selection shown by video reverse)
;;; never resolved to a colour either way — its default "reverse" and the
;;; registry's "#{E:mode-style}" both parse to a plist with no :fg/:bg key,
;;; so SELECTION-FG/-BG were always NIL and the highlight always came from
;;; the reverse-video XOR in %pane-cell-attrs (below), never from a colour
;;; substitution here.  Deleting the dead colour path leaves that XOR as the
;;; only mechanism, matching the fixed decision exactly.

(defconstant +copy-mode-mark-fg+ 0
  "Cell-colour index for the copy-mode mark row's foreground (black).
   copy-mode-mark-style's fixed value is \"bg=red,fg=black\"; see the note above.")
(defconstant +copy-mode-mark-bg+ 1
  "Cell-colour index for the copy-mode mark row's background (red).")

(defun %resolve-pane-style-colours (pane)
  "Return PANE's fixed style colours as a PANE-STYLE-COLOURS struct.
   DEF-FG/DEF-BG and SELECTION-FG/-BG are always NIL (see the note above this
   function); only MARK-FG/MARK-BG carry a real colour."
  (declare (ignore pane))
  (make-pane-style-colours
   :def-fg nil :def-bg nil
   :selection-fg nil :selection-bg nil
   :mark-fg +copy-mode-mark-fg+ :mark-bg +copy-mode-mark-bg+))

(defun %render-pane-body (stream screen pane-height pane-width
                          origin-x origin-y
                          colours
                          &optional viewport)
  "Render every row of PANE's screen content to STREAM under the screen
   lock, then clear the screen's dirty flag.  COLOURS is the
   PANE-STYLE-COLOURS struct from %resolve-pane-style-colours.
   copy-mode-line-numbers is fixed \"off\" (§1.4), so there is no gutter to
   reserve — content always fills the pane's full width."
  (with-lock-held ((screen-lock screen))
    ;; Hoist selection boundary computation outside the cell loop so it is
    ;; computed once per frame instead of once per cell (~1920 times).
    (multiple-value-bind (sel-active sel-start-row sel-end-row sel-start-col sel-end-col
                          sel-rect-p sel-mark-row sel-mark-col)
        (%compute-selection-bounds screen)
      ;; sgr-register bundles the mutable last-emitted SGR state so
      ;; %render-cell-row can detect and suppress redundant attribute sequences.
      (let ((sgr-reg (make-sgr-register))
            (sel     (make-selection-bounds :active sel-active
                                            :start-row sel-start-row :end-row sel-end-row
                                            :start-col sel-start-col :end-col sel-end-col
                                            :rect-p sel-rect-p
                                            :mark-row sel-mark-row :mark-col sel-mark-col)))
        (loop for row below pane-height do
          (when (plusp pane-width)
            (move-to stream (+ origin-y row) origin-x)
            (%render-cell-row stream screen pane-width row
                              sel
                              sgr-reg
                              (pane-style-def-fg colours) (pane-style-def-bg colours)
                              (pane-style-selection-fg colours) (pane-style-selection-bg colours)
                              (pane-style-mark-fg colours) (pane-style-mark-bg colours)
                              viewport)))
        ;; Close any hyperlink still open at the end of the pane (OSC 8 ; ;).
        (when (sgr-reg-hyperlink sgr-reg)
          (write-string (format nil "~C]8;;~C\\" #\Escape #\Escape) stream)))))
  (screen-clear-dirty screen))

(defun render-pane (stream session pane &key (viewport 0))
  "Draw the pane's screen into the real terminal at the pane's (x, y) offset."
  (declare (ignore session))
  (let* ((screen      (pane-screen  pane))
         (pane-width  (pane-width  pane))
         (pane-height (pane-height pane))
         (origin-x    (pane-x     pane))
         (origin-y    (pane-y     pane)))
    (%render-pane-body stream screen pane-height pane-width
                       origin-x origin-y
                       (%resolve-pane-style-colours pane)
                       viewport)
    ;; Copy-mode overlay is rendered as a right-aligned slice so it does not
    ;; repaint the whole pane row.
    (%render-copy-mode-position-overlay stream pane
                                        origin-x origin-y pane-width)))

(in-package #:nerimux/renderer)

(defun %surface-from-ansi-frame (frame rows cols &key (viewport 0))
  "Parse FRAME into a headless CL-TUI-KIT/CORE surface, preserving SGR
   styling (R-style-preservation).

   Previously this drew through CL-TUI-KIT/WIDGETS's text-widget +
   viewport-widget pair for VIEWPORT > 0 (unstyled, and separately from the
   VIEWPORT = 0 path below).  A VIEWPORT-WIDGET renders its child clipped to
   AREA at (0, -OFFSET-Y): with AREA = (0 0 COLS ROWS) and OFFSET-Y =
   VIEWPORT, that shows content rows [VIEWPORT, VIEWPORT+ROWS) at surface
   rows [0, ROWS) -- exactly the window drawn row-by-row below, so dropping
   the widget path changes no visible output for VIEWPORT > 0, and folding
   VIEWPORT = 0 into the same CONTENT-HEIGHT = ROWS case (viewport offset
   0) unifies what were two separate code paths."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (viewport (max 0 viewport))
         (content-height (+ rows viewport))
         (surface (cl-tui-kit/core:make-surface cols rows)))
    (multiple-value-bind (grid style-grid)
        (%ansi-frame-grid frame content-height cols)
      (dotimes (surface-row rows surface)
        (let ((content-row (+ surface-row viewport)))
          (cl-tui-kit/core:surface-draw-styled-text
           surface 0 surface-row
           (%frame-grid-row-spans (%frame-grid-row grid content-row)
                                  (%frame-grid-style-row style-grid content-row))
           :max-width cols))))))

(defun %surface-to-ansi-frame (surface)
  (let ((escape (code-char 27))
        (previous-style nil))
    (with-output-to-string (stream)
      (format stream "~C[2J~C[H" escape escape)
      (dotimes (row (cl-tui-kit/core:surface-height surface))
        (setf previous-style nil)
        (dotimes (column (cl-tui-kit/core:surface-width surface))
          (let ((cell (cl-tui-kit/core:surface-cell surface column row)))
            (unless (cl-tui-kit/core:cell-continuation-p cell)
              (let ((style (cl-tui-kit/core:cell-style cell)))
                (unless (and previous-style
                             (cl-tui-kit/core:style= previous-style style))
                  (write-string (cl-tui-kit/ansi:ansi-encode-style style)
                                stream)
                  (setf previous-style style)))
              (write-string (cl-tui-kit/core:cell-content cell) stream))))
        (unless (= row (1- (cl-tui-kit/core:surface-height surface)))
          ;; CR+LF, not TERPRI's bare #\Newline: the client's tty is in raw
          ;; mode (OPOST off), so the terminal receives these bytes verbatim
          ;; with no ONLCR translation.  A bare LF moves down without
          ;; returning the column; after each full-width row the frame
          ;; staircases past the right margin and its top half scrolls off
          ;; the screen -- a real terminal showed only the empty panel
          ;; bottoms and the status line.  No automated check caught this
          ;; because every screen model in reach (pyte drivers, the
          ;; frame-grid parser above) treats LF as CR+LF.
          (write-string #.(coerce (list #\Return #\Linefeed) 'string)
                        stream)))
      (write-string (cl-tui-kit/ansi:ansi-encode-style
                     (cl-tui-kit/core:make-style))
                    stream))))

;;; ── Terminal-too-small guard (R6.10) ────────────────────────────────────────
;;;
;;; Placed in %RENDER-ANSI-FRAME-WITH-TUI-KIT rather than in either public
;;; entry point separately: RENDER-SESSION-TO-TUI-STRING (pane view) and
;;; RENDER-WORKSPACE-OVERVIEW-TO-TUI-STRING (workspace overview) both funnel
;;; through this one function, so putting the guard here covers both without
;;; duplicating it. ROWS/COLS are read fresh on every call (the server passes
;;; the client's current size each frame, not stored state), so recovery on
;;; resize falls out of that per-frame re-evaluation rather than needing any
;;; dedicated "was too small" flag.

(defconstant +min-terminal-cols+ 40)
(defconstant +min-terminal-rows+ 10)

(defun %terminal-too-small-p (rows cols)
  (or (< rows +min-terminal-rows+) (< cols +min-terminal-cols+)))

(defun %render-terminal-too-small-surface (rows cols)
  "A ROWS x COLS surface containing only the centred too-small warning."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (message (format nil "terminal too small (need ~Dx~D)"
                          +min-terminal-cols+ +min-terminal-rows+))
         (text (%display-clip message cols))
         (row (floor rows 2))
         (col (%center-coord cols (%display-width text))))
    (cl-tui-kit/core:surface-draw-text surface col row text :max-width cols)
    surface))

(defun %render-ansi-frame-with-tui-kit
    (frame rows cols &key (viewport 0) widget-renderer)
  (let* ((too-small-p (%terminal-too-small-p rows cols))
         (surface (if too-small-p
                      (%render-terminal-too-small-surface rows cols)
                      (%surface-from-ansi-frame frame rows cols
                                                :viewport viewport))))
    (when (and widget-renderer (not too-small-p))
      (funcall widget-renderer surface))
    (%surface-to-ansi-frame surface)))

(defun render-session-to-tui-string (session terminal-rows terminal-cols
                                     &key focus-pane (viewport 0) (mode :normal)
                                       (picker-items nil) (picker-query "")
                                       (picker-index 0) (picker-regex-p nil)
                                       (command-buffer ""))
  "Render a client frame through cl-tui-kit's headless surface/widget path."
  (let* ((widget-renderer
           (when (eq mode :picker)
             (lambda (surface)
               (%render-picker-widget
                surface terminal-rows terminal-cols picker-items picker-query
                picker-index picker-regex-p))))
         ;; R6.11: the OSC-0 title RENDER-SESSION-TO-STRING embeds in its
         ;; frame text does not survive %RENDER-ANSI-FRAME-WITH-TUI-KIT's
         ;; ansi-frame/tui-kit round-trip (its frame-grid parser skips OSC
         ;; sequences without retaining them, then the surface is redrawn
         ;; from the parsed grid) -- re-derive the same pane here and
         ;; re-emit after the round-trip, at the boundary a client actually
         ;; receives.
         (active-pane (%session-title-pane session focus-pane))
         (worktree (and active-pane (pane-worktree active-pane))))
    (concatenate
     'string
     (%render-ansi-frame-with-tui-kit
      (render-session-to-string
       session terminal-rows terminal-cols
       :focus-pane focus-pane
       :viewport viewport
       :mode (if (eq mode :picker) :normal mode)
       :picker-items picker-items
       :picker-query picker-query
       :picker-index picker-index
       :picker-regex-p picker-regex-p
       :command-buffer command-buffer)
      terminal-rows terminal-cols
      :viewport 0
      :widget-renderer widget-renderer)
     (%client-title-osc (and worktree (worktree-repository worktree)) worktree))))

(defun render-workspace-overview-to-tui-string
    (organizations terminal-rows terminal-cols &key focus-pane
                                               selected-tree-object
                                               selected-worktree
                                               (tree-scroll 0)
                                               (messages nil)
                                               (mode :normal)
                                               (prefix-code #x11)
                                               expanded-node-ids
                                               refreshing-ids
                                               stale-ids
                                               (scanning-p nil)
                                               (command-buffer ""))
  "Render the workspace overview through cl-tui-kit's headless backend.
   EXPANDED-NODE-IDS / REFRESHING-IDS / STALE-IDS / SCANNING-P /
   COMMAND-BUFFER are forwarded to RENDER-WORKSPACE-OVERVIEW-TO-STRING and,
   for the tree, to %RENDER-WORKSPACE-TREE-WIDGET -- see that function and
   %WORKSPACE-FLAT-TREE-ENTRIES (renderer-workspace-tree.lisp) for what each one
   means (R6.2/R6.3)."
  ;; R6.11: same round-trip-discards-OSC situation as
  ;; render-session-to-tui-string above -- re-derive the title selection at
  ;; this boundary and re-emit after the round-trip.
  (multiple-value-bind (title-repository title-worktree)
      (%workspace-title-selection focus-pane selected-tree-object
                                  selected-worktree)
    (concatenate
     'string
     (%render-ansi-frame-with-tui-kit
      (render-workspace-overview-to-string
       organizations terminal-rows terminal-cols
       :focus-pane focus-pane
       :selected-tree-object selected-tree-object
       :selected-worktree selected-worktree
       :tree-scroll tree-scroll
       :messages messages
       :mode mode
       :prefix-code prefix-code
       :render-tree-p nil
       :expanded-node-ids expanded-node-ids
       :refreshing-ids refreshing-ids
       :stale-ids stale-ids
       :scanning-p scanning-p
       :command-buffer command-buffer)
      terminal-rows terminal-cols
      :viewport 0
      :widget-renderer
      ;; R6.2: while the initial scan is still running there is nothing for
      ;; the tree widget to draw -- the ANSI pass above already rendered the
      ;; "scanning..." placeholder frame, so skip overlaying an empty tree
      ;; box on top of it.
      (unless (and scanning-p (null organizations))
        (lambda (surface)
          (%render-workspace-tree-widget
           surface organizations terminal-rows terminal-cols
           selected-tree-object tree-scroll
           :expanded-node-ids expanded-node-ids
           :refreshing-ids refreshing-ids
           :stale-ids stale-ids))))
     (%client-title-osc title-repository title-worktree))))

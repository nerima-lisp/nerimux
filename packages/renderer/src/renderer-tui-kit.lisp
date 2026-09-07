(in-package #:nerimux/renderer)

(defun %box-widget-inner-rectangle (rectangle)
  "The content rectangle CL-TUI-KIT/WIDGETS:BOX-WIDGET gives its child for
   RECTANGLE, with the default single-cell border and single-cell padding
   (BOX-WIDGET's WIDGET-RENDER, cl-tui-kit's src/widgets.lisp): inset by 1
   for the border, then by another 1 for the padding slot's own default --
   2 columns/rows total on every side. The confirm view and the help view
   both draw their content directly onto the surface instead of through a
   BOX-WIDGET child (a per-line TEXT-WIDGET can only take one style for its
   whole line, and both views need more than one colour per line), so both
   replicate the inset BOX-WIDGET would have given a child by calling the
   library's own geometry functions here, rather than each hand-computing it
   and risking the two disagreeing."
  (cl-tui-kit/core:rectangle-inset
   (cl-tui-kit/core:rectangle-inset rectangle
                                    (cl-tui-kit/core:make-padding :all 1))
   (cl-tui-kit/core:make-padding :all 1)))

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
          (cl-tui-kit/core:surface-draw-styled-text surface
                                                    0
                                                    surface-row
                                                    (%frame-grid-row-spans
                                                     (%frame-grid-row grid
                                                                      content-row)
                                                     (%frame-grid-style-row
                                                      style-grid
                                                      content-row))
                                                    :max-width
                                                    cols))))))

(defstruct (ansi-row-snapshot (:constructor %make-ansi-row-snapshot))
  (rows #() :read-only t)
  (width 0 :read-only t)
  (footer "" :read-only t)
  (title "" :read-only t))

(defun %surface-ansi-row (surface row)
  (let ((previous-style nil))
    (with-output-to-string (stream)
      (format stream "~C[~D;1H~C[0m" (code-char 27) (1+ row) (code-char 27))
        (dotimes (column (cl-tui-kit/core:surface-width surface))
          (let ((cell (cl-tui-kit/core:surface-cell surface column row)))
            (unless (cl-tui-kit/core:cell-continuation-p cell)
              (let ((style (cl-tui-kit/core:cell-style cell)))
                (unless (and previous-style
                             (cl-tui-kit/core:style= previous-style style))
                  (write-string (cl-tui-kit/ansi:ansi-encode-style style)
                                stream)
                  (setf previous-style style)))
              (write-string (cl-tui-kit/core:cell-content cell) stream)))))))

(defun %surface-to-ansi-frame (surface)
  (let* ((height (cl-tui-kit/core:surface-height surface))
         (width (cl-tui-kit/core:surface-width surface))
         (rows (map 'vector (lambda (row) (%surface-ansi-row surface row))
                    (loop for row below height collect row)))
         (footer (format nil "~C[0m~C[~D;~DH" (code-char 27) (code-char 27)
                         height width))
         (snapshot (%make-ansi-row-snapshot :rows rows :width width
                                           :footer footer)))
    (values (with-output-to-string (stream)
              (format stream "~C[2J" (code-char 27))
              (map nil (lambda (row) (write-string row stream)) rows)
              (write-string footer stream))
            snapshot)))

(defun ansi-row-delta (previous current)
  "Return a compatible row update, or NIL when a full repaint is required."
  (when (and previous current
             (= (ansi-row-snapshot-width previous)
                (ansi-row-snapshot-width current))
             (= (length (ansi-row-snapshot-rows previous))
                (length (ansi-row-snapshot-rows current))))
    (with-output-to-string (stream)
      (let ((changed nil))
        (loop for old across (ansi-row-snapshot-rows previous)
              for new across (ansi-row-snapshot-rows current)
              unless (string= old new)
                do (write-string new stream) (setf changed t))
        (when changed (write-string (ansi-row-snapshot-footer current) stream)))
      (unless (string= (ansi-row-snapshot-title previous)
                       (ansi-row-snapshot-title current))
        (write-string (ansi-row-snapshot-title current) stream)))))

(defun %ansi-frame-with-title (frame snapshot title)
  (values (concatenate 'string frame title)
          (when snapshot
            (%make-ansi-row-snapshot
             :rows (ansi-row-snapshot-rows snapshot)
             :width (ansi-row-snapshot-width snapshot)
             :footer (ansi-row-snapshot-footer snapshot) :title title))))

(defconstant +min-terminal-cols+
  40)

(defconstant +min-terminal-rows+
  10)

(defun %terminal-too-small-p (rows cols)
  (or (< rows +min-terminal-rows+) (< cols +min-terminal-cols+)))

(defun %render-terminal-too-small-surface (rows cols)
  "A ROWS x COLS surface containing only the centred too-small warning."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (message
          (format nil
                  "terminal too small (need ~Dx~D)"
                  +min-terminal-cols+
                  +min-terminal-rows+))
         (text (%display-clip message cols))
         (row (floor rows 2))
         (col (%center-coord cols (%display-width text))))
    (cl-tui-kit/core:surface-draw-text surface col row text :max-width cols)
    surface))

(defun %render-ansi-frame-with-tui-kit (frame rows
                                              cols
                                              &key
                                              (viewport 0)
                                              widget-renderer)
  (let* ((too-small-p (%terminal-too-small-p rows cols))
         (surface
          (if too-small-p
              (%render-terminal-too-small-surface rows cols)
              (%surface-from-ansi-frame frame rows cols :viewport viewport))))
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
                                               collapsed-node-ids
                                               expanded-node-ids
                                               refreshing-ids
                                               job-labels
                                               stale-ids
                                               file-diffs
                                               (scanning-p nil)
                                               (scan-progress nil)
                                               (catalog-empty-hint nil)
                                               (command-buffer "")
                                               (tree-filter nil))
  "Render the workspace overview through cl-tui-kit's headless backend.
   COLLAPSED-NODE-IDS / EXPANDED-NODE-IDS / REFRESHING-IDS / STALE-IDS /
   FILE-DIFFS / SCANNING-P / SCAN-PROGRESS / CATALOG-EMPTY-HINT /
   COMMAND-BUFFER / TREE-FILTER are forwarded to RENDER-WORKSPACE-OVERVIEW-
   TO-STRING and, for the tree, to %RENDER-WORKSPACE-TREE-WIDGET -- see that
   function and %WORKSPACE-FLAT-TREE-ENTRIES (renderer-workspace-tree.lisp)
   for what each one means.
   The tree is flattened/filtered exactly ONCE per frame, right here, and
   the result threaded through to both RENDER-WORKSPACE-OVERVIEW-TO-STRING
   (:PRECOMPUTED-TREE-ENTRIES) and %RENDER-WORKSPACE-TREE-WIDGET
   (:PRECOMPUTED-ENTRIES) below. Before this, one frame walked the (possibly
   large) org/repo/worktree/pane graph up to three times: once here for
   NO-MATCHES-P, again inside the ANSI pass, and a third time inside the
   tree widget."
  (let ((all-tree-entries
          (%workspace-flat-tree-entries
           organizations collapsed-node-ids
           :job-labels job-labels
           :refreshing-ids refreshing-ids
           :stale-ids stale-ids
           :filter tree-filter
           :expanded-node-ids expanded-node-ids
           :file-diffs file-diffs)))
    (multiple-value-bind (title-repository title-worktree)
        (%workspace-title-selection focus-pane selected-tree-object
                                    selected-worktree)
      (let ((no-matches-p
              (and organizations
                   (plusp (length (or tree-filter "")))
                   (null all-tree-entries))))
        (multiple-value-bind (frame snapshot)
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
           :collapsed-node-ids collapsed-node-ids
           :expanded-node-ids expanded-node-ids
           :refreshing-ids refreshing-ids
           :stale-ids stale-ids
           :file-diffs file-diffs
           :scanning-p scanning-p
           :scan-progress scan-progress
           :catalog-empty-hint catalog-empty-hint
           :command-buffer command-buffer
           :tree-filter tree-filter
           :precomputed-tree-entries all-tree-entries)
          terminal-rows terminal-cols
          :viewport 0
          :widget-renderer
          (unless (and (null organizations)
                       (or scanning-p catalog-empty-hint))
            (unless no-matches-p
              (lambda (surface)
                (%render-workspace-tree-widget
                 surface organizations terminal-rows terminal-cols
                 selected-tree-object tree-scroll
                 :collapsed-node-ids collapsed-node-ids
                 :expanded-node-ids expanded-node-ids
                 :refreshing-ids refreshing-ids
                 :stale-ids stale-ids
                 :filter tree-filter
                 :file-diffs file-diffs
                 :precomputed-entries all-tree-entries)))))
          (%ansi-frame-with-title
           frame snapshot (%client-title-osc title-repository title-worktree)))))))

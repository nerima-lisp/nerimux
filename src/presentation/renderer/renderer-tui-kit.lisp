(in-package #:nerimux/renderer)

(defun %make-frame-grid (rows cols)
  (let ((grid (make-array rows)))
    (dotimes (row rows grid)
      (setf (aref grid row) (make-string cols :initial-element #\Space)))))

(defun %clear-frame-grid (grid)
  (dotimes (row (length grid))
    (fill (aref grid row) #\Space))
  grid)

(defun %frame-grid-params (text)
  (let ((start 0)
        (length (length text))
        (params nil))
    (when (and (plusp length)
               (find (char text 0) "? > !" :test #'char=))
      (incf start))
    (loop for end from start to length
          when (or (= end length)
                   (char= (char text end) #\;))
            do (push (or (parse-integer (subseq text start end)
                                         :junk-allowed t)
                         0)
                     params)
               (setf start (1+ end)))
    (nreverse params)))

(defun %frame-grid-param (params index default)
  (let ((value (nth index params)))
    (if (and value (plusp value)) value default)))

(defun %frame-grid-clear-line (row col mode)
  (case mode
    (1 (fill row #\Space :start 0 :end (min (1+ col) (length row))))
    (2 (fill row #\Space))
    (otherwise (fill row #\Space :start (min col (length row))))))

(defun %frame-grid-apply-csi (grid row col saved-row saved-col params final)
  (let ((height (length grid))
        (width (length (aref grid 0)))
        (count (or (first params) 1)))
    (case final
      ((#\A #\B)
       (let ((delta (if (plusp count) count 1)))
         (if (char= final #\A)
             (decf row delta)
             (incf row delta))))
      ((#\C #\D)
       (let ((delta (if (plusp count) count 1)))
         (if (char= final #\C)
             (incf col delta)
             (decf col delta))))
      ((#\G)
       (setf col (1- (%frame-grid-param params 0 1))))
      ((#\d)
       (setf row (1- (%frame-grid-param params 0 1))))
      ((#\H #\f)
       (setf row (1- (%frame-grid-param params 0 1))
             col (1- (%frame-grid-param params 1 1))))
      ((#\J)
       (when (member (or (first params) 0) '(2 3))
         (%clear-frame-grid grid)))
      ((#\K)
       (%frame-grid-clear-line (aref grid (max 0 (min row (1- height))))
                               col
                               (or (first params) 0)))
      ((#\s)
       (setf saved-row row
             saved-col col))
      ((#\u)
       (setf row saved-row
             col saved-col)))
    (values (max 0 (min row (1- height)))
            (max 0 (min col width))
            saved-row
            saved-col)))

(defun %frame-grid-put-char (grid row col character)
  (let ((height (length grid))
        (width (length (aref grid 0))))
    (when (and (<= 0 row) (< row height)
               (<= 0 col) (< col width))
      (setf (char (aref grid row) col) character))
    (if (< (1+ col) width)
        (1+ col)
        0)))

(defun %frame-grid-parse-csi (frame start grid row col saved-row saved-col)
  (let ((end start)
        (length (length frame)))
    (loop while (and (< end length)
                     (not (<= (char-code #\@)
                              (char-code (char frame end))
                              (char-code #\~))))
          do (incf end))
    (if (= end length)
        (values length row col saved-row saved-col)
        (multiple-value-bind (new-row new-col new-saved-row new-saved-col)
            (%frame-grid-apply-csi
             grid row col saved-row saved-col
             (%frame-grid-params (subseq frame start end))
             (char frame end))
          (values (1+ end) new-row new-col new-saved-row new-saved-col)))))

(defun %frame-grid-skip-osc (frame start)
  (let ((index start)
        (length (length frame)))
    (loop while (< index length)
          do (cond
               ((= (char-code (char frame index)) 7)
                (return (1+ index)))
               ((and (= (char-code (char frame index)) 27)
                     (< (1+ index) length)
                     (char= (char frame (1+ index)) #\\))
                (return (+ index 2)))
               (t (incf index)))
          finally (return length))))

(defun %ansi-frame-grid (frame rows cols)
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (grid (%make-frame-grid rows cols))
         (row 0)
         (col 0)
         (saved-row 0)
         (saved-col 0)
         (index 0)
         (length (length frame)))
    (loop while (< index length)
          do (let ((character (char frame index)))
               (cond
                 ((= (char-code character) 27)
                  (if (>= (1+ index) length)
                      (incf index)
                      (case (char frame (1+ index))
                        (#\[
                         (multiple-value-setq
                             (index row col saved-row saved-col)
                           (%frame-grid-parse-csi
                            frame (+ index 2) grid row col
                            saved-row saved-col)))
                        (#\]
                         (setf index (%frame-grid-skip-osc frame (+ index 2))))
                        (otherwise
                         (incf index 2)))))
                 ((char= character #\Newline)
                  (setf col 0
                        row (min (1+ row) (1- rows)))
                  (incf index))
                 ((char= character #\Return)
                  (setf col 0)
                  (incf index))
                 ((char= character #\Backspace)
                  (setf col (max 0 (1- col)))
                  (incf index))
                 ((char= character #\Tab)
                  (setf col (min (1- cols)
                                 (* 8 (1+ (floor col 8)))))
                  (incf index))
                 ((>= (char-code character) 32)
                  (setf col (%frame-grid-put-char grid row col character))
                  (when (zerop col)
                    (setf row (min (1+ row) (1- rows))))
                  (incf index))
                 (t
                  (incf index)))))
    grid))

(defun %frame-grid-row (grid row)
  (aref grid row))

(defun %frame-grid-text (grid)
  (with-output-to-string (stream)
    (dotimes (row (length grid))
      (write-string (%frame-grid-row grid row) stream)
      (unless (= row (1- (length grid)))
        (terpri stream)))))

(defun %frame-area (rows cols)
  (let* ((bounds (cl-tui-kit/core:make-rectangle 0 0 cols rows))
         (layout
           (cl-tui-kit/layout:make-viewport-layout
            (cl-tui-kit/layout:make-layout-item
             :nerimux-frame
             :constraints
             (cl-tui-kit/core:make-constraints
              :min-width cols
              :preferred-width cols
              :min-height rows
              :preferred-height rows)))))
    (cl-tui-kit/layout:layout-child-rectangle
     layout :nerimux-frame bounds)))

(defun %workspace-tree-widget-key (node)
  (typecase node
    (organization (list :organization (organization-id node)))
    (repository (list :repository (repository-id node)))
    (worktree (list :worktree (worktree-id node)))
    (t (list :workspace-object node))))

(defun %workspace-tree-widget-label (node)
  (labels ((value (candidate fallback)
             (let ((text (and candidate (princ-to-string candidate))))
               (if (and text (plusp (length text))) text fallback)))
           (attention-mark (attention-p)
             (if attention-p "!" " ")))
    (typecase node
      (organization
       (format nil "org ~A ~A ~A [~A]"
               (attention-mark
                (or (plusp (organization-attention-count node))
                    (organization-attention-worktrees node)))
               (value (or (and (plusp (length (organization-host node)))
                               (organization-host node))
                           (and (plusp (length (organization-name node)))
                                (organization-name node)))
                      (organization-id node))
               (value (organization-name node) "default")
               (if (organization-missing-p node) "MISSING"
                   (format nil "~D repo~:P"
                           (length (organization-repositories node))))))
      (repository
       (format nil "repo ~A ~A [~A]"
               (attention-mark
                (or (repository-dirty-p node)
                    (repository-conflict-p node)
                    (plusp (repository-ahead node))
                    (plusp (repository-behind node))
                    (repository-missing-p node)
                    (some #'worktree-attention-p
                          (repository-worktrees node))))
               (value (or (and (plusp (length (repository-specification node)))
                               (repository-specification node))
                           (and (plusp (length (repository-local-path node)))
                                (repository-local-path node)))
                      (repository-id node))
               (cond
                 ((repository-missing-p node) "MISSING")
                 ((repository-conflict-p node) "CONFLICT")
                 ((repository-dirty-p node) "DIRTY")
                 ((null (repository-worktrees node)) "NO-WORKTREE")
                 (t (format nil "~D wt~:P"
                            (length (repository-worktrees node)))))))
      (worktree
       (format nil "wt ~A ~A [~A]"
               (attention-mark (worktree-attention-p node))
               (value (worktree-branch node)
                      (value (worktree-path node) (worktree-id node)))
               ;; R6.1: every applicable status token, not just the first
               ;; match of a single-choice cond -- see %worktree-status-tokens
               ;; in renderer-workspace.lisp (loads before this file) for the
               ;; CLEAN/UNKNOWN distinction this delegates to.
               (%worktree-status-label node)))
      (t (princ-to-string node)))))

(defun %workspace-tree-visible-entries (organizations offset limit)
  (let* ((offset (max 0 offset))
         (limit (max 0 limit))
         (index 0)
         (end (+ offset limit))
         (entries nil))
    (labels ((visit (level node)
               (when (>= index end)
                 (throw 'workspace-tree-visible-entries-done nil))
               (when (>= index offset)
                 (push (cons level node) entries))
               (incf index)))
      (catch 'workspace-tree-visible-entries-done
        (dolist (organization organizations)
          (visit 0 organization)
          (dolist (repository (organization-repositories organization))
            (visit 1 repository)
            (dolist (worktree (repository-worktrees repository))
              (visit 2 worktree))))))
    (nreverse entries)))

(defun %render-workspace-tree-widget
    (surface organizations rows cols selected-tree-object tree-scroll)
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (multi-column-p (>= cols 9))
         (left-width (if multi-column-p
                         (max 1 (min 30 (floor cols 3)))
                         0))
         (body-start 1)
         (body-end (max body-start (- rows 2)))
         (visible-rows (max 1 (- body-end (1+ body-start))))
         (tree-scroll (max 0 (or tree-scroll 0))))
    (when (and multi-column-p
               organizations
               (> body-end (1+ body-start)))
      (let ((rectangle
              (cl-tui-kit/core:make-rectangle
               0 (1+ body-start) left-width
               (max 1 (- body-end (1+ body-start))))))
        (let* ((entries (%workspace-tree-visible-entries
                         organizations tree-scroll visible-rows))
               (model
                 (cl-tui-kit/widgets:make-list-model
                  :count (length entries)
                  :item-at (lambda (index) (nth index entries))
                  :key-at (lambda (entry index)
                            (declare (ignore index))
                            (%workspace-tree-widget-key (cdr entry)))
                  :label-at (lambda (entry index)
                              (declare (ignore index))
                              (format nil "~A~A"
                                      (make-string (* 2 (car entry))
                                                   :initial-element #\Space)
                                      (%workspace-tree-widget-label
                                       (cdr entry))))
                  :render-item
                  (lambda (entry index)
                    (declare (ignore index))
                    (format nil "~A~A"
                            (make-string (* 2 (car entry))
                                         :initial-element #\Space)
                            (%workspace-tree-widget-label (cdr entry)))))))
        (cl-tui-kit/widgets:render-widget
         (cl-tui-kit/widgets:make-list-widget
          model
          :id :nerimux-workspace-tree
          :rectangle rectangle
          :selected-key
          (and selected-tree-object
               (%workspace-tree-widget-key selected-tree-object))
          :offset 0
          :focusable-p nil)
         surface
         rectangle))))))

(defun %picker-widget-key (item)
  (list :picker-item (nerimux/picker:picker-item-id item)))

(defun %render-picker-widget
    (surface rows cols items query index regex-p)
  (let* ((items (or items nil))
         (query (if (stringp query) query (princ-to-string query)))
         (index (max 0 (min (max 0 (1- (length items))) (or index 0))))
         (selected-item (nth index items))
         (list-model
           (cl-tui-kit/widgets:make-list-model
            :count (length items)
            :item-at (lambda (position) (nth position items))
            :key-at (lambda (item position)
                      (declare (ignore position))
                      (%picker-widget-key item))
            :label-at (lambda (item position)
                        (declare (ignore position))
                        (%picker-item-display-text item))
            :render-item (lambda (item position)
                           (declare (ignore position))
                           (%picker-item-display-text item))))
         (title
           (cl-tui-kit/widgets:make-text-widget
            (format nil
                    "GLOBAL PICKER [~:[literal~;regex~]] | search workspace"
                    regex-p)
            :id :nerimux-picker-title))
         (input
           (cl-tui-kit/widgets:make-input-widget
            :value query
            :placeholder "search workspace, repository, worktree, or pane"
            :id :nerimux-picker-query
            :focusable-p nil))
         (results
           (cl-tui-kit/widgets:make-list-widget
            list-model
            :id :nerimux-picker-results
            :selected-key
            (and selected-item (%picker-widget-key selected-item))
            :row-height 1
            :focusable-p nil))
         (status
           (cl-tui-kit/widgets:make-text-widget
            (if items
                (format nil "~D result~:P" (length items))
                "no matches")
            :id :nerimux-picker-status))
         (form
           (cl-tui-kit/widgets:make-form-widget
            (list title input results status)
            :id :nerimux-picker-form
            :focusable-p nil))
         (modal
           (cl-tui-kit/widgets:make-modal-widget
            form
            :id :nerimux-global-picker
            :rectangle (%frame-area rows cols)
            :open-p t
            :focusable-p nil
            :outside-close-p nil)))
    (cl-tui-kit/widgets:render-widget
     modal surface (%frame-area rows cols))))

(defun %surface-from-ansi-frame (frame rows cols &key (viewport 0))
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (viewport (max 0 viewport)))
    (if (zerop viewport)
        (let* ((grid (%ansi-frame-grid frame rows cols))
               (surface (cl-tui-kit/core:make-surface cols rows)))
          (cl-tui-kit/core:surface-draw-text
           surface 0 0 (%frame-grid-text grid) :max-width cols)
          surface)
        (let* ((rectangle (%frame-area rows cols))
               (content-height (+ rows viewport))
               (content-rectangle
                 (cl-tui-kit/core:make-rectangle 0 0 cols content-height))
               (grid (%ansi-frame-grid frame content-height cols))
               (text
                 (cl-tui-kit/widgets:make-text-widget
                  (%frame-grid-text grid)
                  :id :nerimux-frame
                  :rectangle content-rectangle))
               (viewport
                 (cl-tui-kit/core:make-viewport
                  :bounds rectangle
                  :content-width cols
                  :content-height content-height
                  :offset-y (max 0 viewport)))
               (root
                 (cl-tui-kit/widgets:make-viewport-widget
                  text
                  :id :nerimux-client-viewport
                  :rectangle rectangle
                  :viewport viewport
                  :content-width cols
                  :content-height content-height))
               (surface (cl-tui-kit/core:make-surface cols rows)))
          (cl-tui-kit/widgets:render-widget root surface rectangle)
          surface))))

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
          (terpri stream)))
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
                                               (prefix-code #x11))
  "Render the workspace overview through cl-tui-kit's headless backend."
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
       :render-tree-p nil)
      terminal-rows terminal-cols
      :viewport 0
      :widget-renderer
      (lambda (surface)
        (%render-workspace-tree-widget
         surface organizations terminal-rows terminal-cols
         selected-tree-object tree-scroll)))
     (%client-title-osc title-repository title-worktree))))


(in-package #:nerimux/renderer)

;;; ── Widget themes ───────────────────────────────────────────────────────────
;;;
;;; cl-tui-kit widgets resolve their colours through theme roles
;;; (:foreground, :selected, :border, …).  These two themes translate the
;;; renderer's SGR palette (renderer-style.lisp) into cl-tui-kit styles: the
;;; tree theme is transparent (list rows sit on the frame's own background),
;;; the panel theme carries a raised dark background for the picker modal so
;;; the dialog reads as a surface above the frame.

(defun %make-workspace-tree-theme ()
  (cl-tui-kit/core:make-theme
   (list
    (cons :foreground (cl-tui-kit/core:make-style))
    (cons :selected (cl-tui-kit/core:make-style
                     :bold t
                     :background (cl-tui-kit/core:indexed-color 237)))
    (cons :accent (cl-tui-kit/core:make-style
                   :bold t
                   :foreground (cl-tui-kit/core:indexed-color 117)))
    (cons :muted (cl-tui-kit/core:make-style
                  :foreground (cl-tui-kit/core:indexed-color 245))))))

(defun %make-picker-panel-theme ()
  (flet ((panel (&rest arguments)
           (apply #'cl-tui-kit/core:make-style
                  :background (cl-tui-kit/core:indexed-color 235)
                  arguments)))
    (cl-tui-kit/core:make-theme
     (list
      (cons :background (panel))
      (cons :foreground (panel))
      (cons :muted (panel :foreground (cl-tui-kit/core:indexed-color 245)))
      (cons :accent (panel :bold t
                           :foreground (cl-tui-kit/core:indexed-color 117)))
      (cons :selected (cl-tui-kit/core:make-style
                       :bold t
                       :background (cl-tui-kit/core:indexed-color 237)))
      (cons :border (panel :foreground (cl-tui-kit/core:indexed-color 111)))
      (cons :title (panel :bold t
                          :foreground (cl-tui-kit/core:indexed-color 117)))
      (cons :warning (panel :bold t
                            :foreground (cl-tui-kit/core:indexed-color 179)))
      (cons :error (panel :bold t
                          :foreground (cl-tui-kit/core:indexed-color 203)))
      (cons :success (panel :foreground (cl-tui-kit/core:indexed-color 114)))))))

(defvar *workspace-tree-theme* (%make-workspace-tree-theme)
  "Theme for the workspace overview's tree list widget.")

(defvar *picker-panel-theme* (%make-picker-panel-theme)
  "Theme for the global picker's modal, input, list, and text widgets.")

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

(defun %tree-entry-render-text (entry width)
  "One tree row's display text: 2 spaces per LEVEL of indent, the `!`
   attention mark or a blank, then LABEL -- and, for a worktree row, a
   right-side info cluster (state tag, ahead/behind, pane count, relative
   last-activity time) clipped to fit WIDTH display columns, built by
   %WORKTREE-TREE-INFO-SUFFIX. This widget draws every row through
   CL-TUI-KIT/WIDGETS's list-widget, which applies one uniform per-row style
   (list.lisp:WIDGET-RENDER draws via SURFACE-DRAW-TEXT with a single STYLE
   argument) rather than parsing embedded SGR -- so only the plain half of
   %WORKTREE-TREE-INFO-SUFFIX's two return values is usable here; the
   coloured STYLED half is for the plain-ANSI render path
   (renderer-workspace.lisp) only."
  (destructuring-bind (level label object kind) entry
    (let* ((prefix (format nil "~A~:[ ~;!~] "
                           (make-string (* 2 level) :initial-element #\Space)
                           (%workspace-tree-node-attention-p object kind)))
           (base (format nil "~A~A" prefix label)))
      (if (eq kind :worktree)
          (let* ((suffix-width (max 0 (- width (%display-width base) 2)))
                 (suffix (%worktree-tree-info-suffix object suffix-width)))
            (if (plusp (length suffix))
                (format nil "~A  ~A" base suffix)
                base))
          base))))

(defun %render-workspace-tree-widget
    (surface organizations rows cols selected-tree-object tree-scroll
     &key collapsed-node-ids refreshing-ids stale-ids filter precomputed-entries)
  "Draw the workspace tree as the overview's only panel (one-column
   redesign, PR2): full terminal width, TERMINAL-ROWS-derived height via
   WORKSPACE-TREE-VIEW-ROWS so this can't disagree with the ANSI pass's own
   row budget for the header/separator/detail/message/footer around it. The
   <9-column narrow-terminal and <7-row narrow/short-terminal fallbacks (the
   ANSI pass's own \"terminal too narrow/short for panels\" messages) are
   unchanged: below either threshold this widget draws nothing and leaves
   the message visible.
   PRECOMPUTED-ENTRIES, when non-NIL, is used directly instead of calling
   %WORKSPACE-FLAT-TREE-ENTRIES again -- RENDER-WORKSPACE-OVERVIEW-TO-TUI-
   STRING (renderer-tui-kit.lisp) already flattens the tree once per frame
   and passes that result here, so this does not walk the same (possibly
   large) org/repo/worktree/pane graph a third time. NIL still means \"not
   supplied\" here too (recompute), so the one frame where FILTER narrows
   the tree to genuinely zero rows recomputes an already-cheap empty
   result -- harmless, not a correctness gap."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (multi-column-p (>= cols 9))
         ;; WORKSPACE-TREE-VIEW-ROWS floors at 1 (MAX 1 (- ROWS 6)), so
         ;; (PLUSP VIEW-ROWS) used to be vacuously true at every ROWS --
         ;; this is the widget's half of the same tall-enough-p ROWS>=7
         ;; floor RENDER-WORKSPACE-OVERVIEW-TO-STRING now enforces, so a
         ;; too-short terminal skips the tree widget instead of squeezing a
         ;; 1-row tree into a layout that no longer has room for it.
         (tall-enough-p (>= rows 7))
         (tree-top 1)
         (view-rows (workspace-tree-view-rows rows))
         (tree-scroll (max 0 (or tree-scroll 0))))
    (when (and multi-column-p tall-enough-p organizations)
      (let ((rectangle
              (cl-tui-kit/core:make-rectangle 0 tree-top cols view-rows)))
        (let* ((all-entries
                 (or precomputed-entries
                     (%workspace-flat-tree-entries
                      organizations collapsed-node-ids
                      :refreshing-ids refreshing-ids :stale-ids stale-ids
                      :filter filter)))
               (entry-count (length all-entries))
               (entries (subseq all-entries
                                (min tree-scroll entry-count)
                                (min (+ tree-scroll view-rows) entry-count)))
               (model
                 (cl-tui-kit/widgets:make-list-model
                  :count (length entries)
                  :item-at (lambda (index) (nth index entries))
                  :key-at (lambda (entry index)
                            (declare (ignore index))
                            (%workspace-tree-node-key (third entry)))
                  :render-item
                  (lambda (entry index)
                    (declare (ignore index))
                    (%tree-entry-render-text entry cols)))))
          (cl-tui-kit/widgets:render-widget
           (cl-tui-kit/widgets:make-list-widget
            model
            :id :nerimux-workspace-tree
            :rectangle rectangle
            :theme *workspace-tree-theme*
            :selected-key
            (and selected-tree-object
                 (%workspace-tree-node-key selected-tree-object))
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
            (format nil "PICKER (~:[literal~;regex~])" regex-p)
            :id :nerimux-picker-title
            :role :title
            :theme *picker-panel-theme*))
         (input
           (cl-tui-kit/widgets:make-input-widget
            :value query
            ;; The leading space is deliberate: cl-tui-kit's input widget
            ;; (v4.1.3) draws its cursor cell even when unfocused, and with
            ;; an empty value that reverse-video cell lands on column 0 --
            ;; over the placeholder's first character.  Giving the cursor a
            ;; space to sit on keeps the whole placeholder readable.
            :placeholder " search workspace, repository, worktree, or pane"
            :id :nerimux-picker-query
            :theme *picker-panel-theme*
            :focusable-p nil))
         (results
           (cl-tui-kit/widgets:make-list-widget
            list-model
            :id :nerimux-picker-results
            :theme *picker-panel-theme*
            :selected-key
            (and selected-item (%picker-widget-key selected-item))
            :row-height 1
            :focusable-p nil))
         (status
           (cl-tui-kit/widgets:make-text-widget
            (if items
                (format nil "~D result~:P" (length items))
                "no matches")
            :id :nerimux-picker-status
            :role :muted
            :theme *picker-panel-theme*))
         (form
           (cl-tui-kit/widgets:make-form-widget
            (list title input results status)
            :id :nerimux-picker-form
            :theme *picker-panel-theme*
            :focusable-p nil))
         (modal
           (cl-tui-kit/widgets:make-modal-widget
            form
            :id :nerimux-global-picker
            :rectangle (%frame-area rows cols)
            :theme *picker-panel-theme*
            :open-p t
            :focusable-p nil
            :outside-close-p nil)))
    (cl-tui-kit/widgets:render-widget
     modal surface (%frame-area rows cols))))

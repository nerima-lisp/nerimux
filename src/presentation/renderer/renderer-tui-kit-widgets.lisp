(in-package #:nerimux/renderer)

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

(defun %tree-entry-render-text (entry)
  "One tree row's display text: 2 spaces per LEVEL of indent, the `!`
   attention mark or a blank, then LABEL."
  (destructuring-bind (level label object kind) entry
    (format nil "~A~:[ ~;!~] ~A"
            (make-string (* 2 level) :initial-element #\Space)
            (%workspace-tree-node-attention-p object kind)
            label)))

(defun %render-workspace-tree-widget
    (surface organizations rows cols selected-tree-object tree-scroll
     &key expanded-node-ids refreshing-ids stale-ids)
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
        (let* ((all-entries
                 (%workspace-flat-tree-entries
                  organizations expanded-node-ids
                  :refreshing-ids refreshing-ids :stale-ids stale-ids))
               (entry-count (length all-entries))
               (entries (subseq all-entries
                                (min tree-scroll entry-count)
                                (min (+ tree-scroll visible-rows) entry-count)))
               (model
                 (cl-tui-kit/widgets:make-list-model
                  :count (length entries)
                  :item-at (lambda (index) (nth index entries))
                  :key-at (lambda (entry index)
                            (declare (ignore index))
                            (%workspace-tree-node-key (third entry)))
                  :label-at (lambda (entry index)
                              (declare (ignore index))
                              (%tree-entry-render-text entry))
                  :render-item
                  (lambda (entry index)
                    (declare (ignore index))
                    (%tree-entry-render-text entry)))))
          (cl-tui-kit/widgets:render-widget
           (cl-tui-kit/widgets:make-list-widget
            model
            :id :nerimux-workspace-tree
            :rectangle rectangle
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

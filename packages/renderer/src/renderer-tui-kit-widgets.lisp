(in-package #:nerimux/renderer)

(defun %make-picker-panel-theme ()
  (flet ((panel (&rest arguments)
           (apply #'cl-tui-kit/core:make-style
                  :background
                  (cl-tui-kit/core:rgb-color 40 42 54)
                  arguments)))
    (cl-tui-kit/core:make-theme
     (list (cons :background (panel))
           (cons :foreground (panel))
           (cons :muted
                 (panel :foreground (cl-tui-kit/core:rgb-color 98 114 164)))
           (cons :accent
                 (panel :bold
                        t
                        :foreground
                        (cl-tui-kit/core:rgb-color 139 233 253)))
           (cons :selected
                 (cl-tui-kit/core:make-style :bold
                                             t
                                             :background
                                             (cl-tui-kit/core:rgb-color 68
                                                                        71
                                                                        90)))
           (cons :border
                 (panel :foreground (cl-tui-kit/core:rgb-color 189 147 249)))
           (cons :title
                 (panel :bold
                        t
                        :foreground
                        (cl-tui-kit/core:rgb-color 139 233 253)))
           (cons :warning
                 (panel :bold
                        t
                        :foreground
                        (cl-tui-kit/core:rgb-color 241 250 140)))
           (cons :error
                 (panel :bold
                        t
                        :foreground
                        (cl-tui-kit/core:rgb-color 255 85 85)))
           (cons :success
                 (panel :foreground (cl-tui-kit/core:rgb-color 80 250 123)))))))

(defvar *picker-panel-theme*
  (%make-picker-panel-theme)
  "Theme for the global picker's modal, input, list, and text widgets.")

(defun %frame-area (rows cols)
  (let* ((bounds (cl-tui-kit/core:make-rectangle 0 0 cols rows))
         (layout
          (cl-tui-kit/layout:make-viewport-layout
           (cl-tui-kit/layout:make-layout-item :nerimux-frame
                                               :constraints
                                               (cl-tui-kit/core:make-constraints
                                                :min-width
                                                cols
                                                :preferred-width
                                                cols
                                                :min-height
                                                rows
                                                :preferred-height
                                                rows)))))
    (cl-tui-kit/layout:layout-child-rectangle layout :nerimux-frame bounds)))

(defun %picker-widget-key (item)
  (list :picker-item (nerimux/picker:picker-item-id item)))

(defparameter +picker-title+
  "Pick a worktree, repository or pane"
  "What the picker is for, in the words of the rows it offers: `Search' named
   the input box rather than the choice being made.")

(defparameter +picker-key-hints+
  "C-n/C-p move  Enter open  C-r regex  Esc close"
  "The picker's keys. Nothing else on screen names them while it is open.")

(defun %picker-regex-flag-text (regex-p picker-status)
  "The regex flag drawn under the query, or NIL when regex mode is off.
   PICKER-STATUS :UNSUPPORTED is FILTER-GLOBAL-PICKER-ITEMS reporting that the
   query did not compile and it fell back to a substring search -- without
   this the rows simply stop matching what the pattern says."
  (when regex-p
    (if (eq picker-status :unsupported)
        "regex: unsupported pattern, matching literally"
        "regex on")))

(defun %render-picker-widget
    (surface rows cols items query index regex-p &optional picker-status)
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
            +picker-title+
            :id :nerimux-picker-title
            :role :title
            :theme *picker-panel-theme*))
         (input
           (cl-tui-kit/widgets:make-input-widget
            :value query
            :placeholder " search workspace, repository, worktree, or pane"
            :id :nerimux-picker-query
            :theme *picker-panel-theme*
            :focusable-p nil))
         (regex-flag (%picker-regex-flag-text regex-p picker-status))
         (flags
           (when regex-flag
             (cl-tui-kit/widgets:make-text-widget
              regex-flag
              :id :nerimux-picker-flags
              :role (if (eq picker-status :unsupported) :warning :muted)
              :theme *picker-panel-theme*)))
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
            (format nil "~D result~:P   ~A" (length items) +picker-key-hints+)
            :id :nerimux-picker-status
            :role :muted
            :theme *picker-panel-theme*))
         (form
           (cl-tui-kit/widgets:make-form-widget
            (remove nil (list title input flags results status))
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

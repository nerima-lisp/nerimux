(in-package #:nerimux/renderer)

(defun %workspace-status-style-plain ()
  (cl-tui-kit/core:make-style))

(defun %workspace-status-style-heading ()
  (cl-tui-kit/core:make-style :bold t :foreground
                              (cl-tui-kit/core:rgb-color 189 147 249)))

(defun %workspace-status-style-muted ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %workspace-status-style-faint ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %workspace-status-style-ok ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 80 250 123)))

(defun %workspace-status-style-warn ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 241 250 140)))

(defun %workspace-status-style-alert ()
  (cl-tui-kit/core:make-style :bold t :foreground
                              (cl-tui-kit/core:rgb-color 255 85 85)))

(defun %workspace-status-style-accent ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %workspace-status-style-accent-bold ()
  (cl-tui-kit/core:make-style :bold t :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %workspace-status-style-orange ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 255 184 108)))

(defun %workspace-status-style-header-chip ()
  (cl-tui-kit/core:make-style :bold t :foreground
                              (cl-tui-kit/core:rgb-color 40 42 54)
                              :background
                              (cl-tui-kit/core:rgb-color 189 147 249)))

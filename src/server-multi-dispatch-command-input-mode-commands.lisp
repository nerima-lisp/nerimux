(in-package #:nerimux)

(defun %client-enter-command-mode (conn &optional (initial-buffer ""))
  (setf (client-conn-command-return-view conn) (client-conn-view conn))
  (%set-client-modal conn :command)
  (setf (client-conn-command-buffer conn) (if (stringp initial-buffer)
                                              initial-buffer
                                              ""))
  (%mark-dirty)
  t)

(defun %client-restore-command-view (conn)
  (let ((view (client-conn-command-return-view conn)))
    (when (and (eq view :pane) (%reject-pending-worktree-attachment conn))
      (return-from %client-restore-command-view nil))
    (when (member view '(:repolist :status :pane) :test #'eq)
      (setf (client-conn-view conn) view))
    (setf (client-conn-command-return-view conn) nil)))

(defun %client-select-pane-direction (session conn direction)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (window (and pane (nerimux/pane:pane-window pane))))
    (when (%reject-pending-worktree-attachment conn :pane pane :window window)
      (return-from %client-select-pane-direction nil))
    (%workspace-prefix-unzoom window)
    (let ((neighbor (and window (pane-neighbor window pane direction))))
      (if neighbor
          (progn
            (%set-client-focus conn neighbor)
            (%mark-dirty)
            t)
          (progn
            (%client-notify conn (format nil "no pane ~A" direction))
            t)))))

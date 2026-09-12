(in-package #:nerimux)

(defun %client-worktree-pane (session worktree)
  (and worktree
       (find worktree
             (all-panes session)
             :key
             #'nerimux/pane:pane-worktree
             :test
             #'eq)))

(defun %open-client-worktree-pane (session conn worktree &key default-command agent-kind)
  (when (%reject-pending-worktree-attachment conn :worktree worktree :pane nil :window nil)
    (return-from %open-client-worktree-pane nil))
  (let ((path (and worktree (worktree-path worktree))))
    (cond
      ((null worktree)
       nil)
      ((%worktree-cancel-pending-p worktree)
       (%client-notify conn "worktree cancellation is pending")
       nil)
      ((and agent-kind (worktree-running-agent-p worktree))
       (%client-notify conn "worktree already has a running agent")
       nil)
      ((not (and (stringp path) (plusp (length path))))
       (%client-notify conn "worktree has no path")
       nil)
      ((worktree-missing-p worktree)
       (%client-notify conn "worktree is missing")
       nil)
      (t
       (handler-case
           (let ((*term-rows* (client-conn-rows conn))
                 (*term-cols* (client-conn-cols conn)))
             (let* ((window (%workspace-new-window
                             session
                             :name (%worktree-window-name worktree)
                             :start-dir path
                             :default-command default-command
                             :start-reader-p nil))
                    (pane (window-active-pane window)))
               (cond
                 ((null pane)
                  (%client-notify conn "worktree pane unavailable")
                  nil)
                 ((not (pane-live-p pane))
                  (setf (pane-agent-kind pane) agent-kind)
                  (pane-mark-startup-failure pane)
                  (worktree-add-pane worktree pane)
                  (%set-client-selected-worktree conn worktree)
                  (%set-client-focus conn pane session)
                  (%client-notify conn "worktree pane failed to start")
                  (%mark-dirty)
                  t)
                 (t
                  (setf (pane-agent-kind pane) agent-kind)
                  (worktree-add-pane worktree pane)
                  (start-reader-thread pane)
                  (%set-client-selected-worktree conn worktree)
                  (%set-client-focus conn pane session)
                  (setf (worktree-completed-p worktree) nil)
                  (%mark-dirty)
                  (values t t)))))
         (error (condition)
           (%client-notify
            conn
            (format nil "worktree open failed: ~A" condition))
           nil))))))

(defun %client-picker-item-pane (session item worktree)
  "The pane a picker row opens: the row's own pane when it names one and that
   pane is still in SESSION, otherwise whatever pane the worktree has."
  (let ((pane (and item (nerimux/picker:picker-item-pane item))))
    (if (and pane (find pane (all-panes session) :test #'eq))
        pane
        (%client-worktree-pane session worktree))))

(defun %select-client-picker-item (session conn)
  (let* ((item (%picker-selected-item conn))
         (worktree (and item (%picker-item-worktree item)))
         (object
          (or worktree
              (and item
                   (or (nerimux/picker:picker-item-repository item)
                       (nerimux/picker:picker-item-organization item)))))
         (pane (%client-picker-item-pane session item worktree))
         (window (and pane (nerimux/pane:pane-window pane))))
    (when (and worktree
               (%reject-pending-worktree-attachment conn :worktree worktree
                                                        :pane pane :window window))
      (return-from %select-client-picker-item nil))
    (cond
      ((and pane window)
        (nerimux/session:session-select-window session window)
        (nerimux/window:window-select-pane window pane)
        (%set-client-selected-worktree conn worktree)
        (%set-client-focus conn pane session)
        (worktree-resume worktree pane)
        (%close-client-picker conn :keep-view t)
        (%mark-dirty)
        t)
      (worktree
       (when (%open-client-worktree-pane session conn worktree)
         (%close-client-picker conn :keep-view t)
         t))
      ((typep object 'nerimux/workspace-model:repository)
       ;; PC-06: a repository row names a place in the tree, not a shell to
       ;; open. Its main worktree is the row the user meant; expanding first
       ;; keeps that row visible instead of parking the cursor on a hidden one.
       (%set-client-selected-tree-object conn object)
       (%client-tree-expand-selected conn)
       (let ((main (nerimux/workspace-model:repository-main-worktree object)))
         (when main
           (%set-client-selected-tree-object conn main)))
       (%close-client-picker conn)
       t)
      ((typep object 'nerimux/workspace-model:organization)
       (%set-client-selected-tree-object conn object)
       (%client-tree-expand-selected conn)
       (%close-client-picker conn)
       t)
      (t nil))))

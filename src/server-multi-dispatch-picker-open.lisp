(in-package #:nerimux)

(defun %client-worktree-pane (session worktree)
  (and worktree
       (find worktree
             (all-panes session)
             :key
             #'nerimux/pane:pane-worktree
             :test
             #'eq)))

(defun %open-client-worktree-pane (session conn worktree &key default-command)
  (let ((path (and worktree (worktree-path worktree))))
    (cond
      ((null worktree)
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
                  (pane-mark-startup-failure pane)
                  (worktree-add-pane worktree pane)
                  (%set-client-selected-worktree conn worktree)
                  (%set-client-focus conn pane)
                  (%client-notify conn "worktree pane failed to start")
                  (%mark-dirty)
                  t)
                 (t
                  (start-reader-thread pane)
                  (worktree-add-pane worktree pane)
                  (%set-client-selected-worktree conn worktree)
                  (%set-client-focus conn pane)
                  (%mark-dirty)
                  t))))
         (error (condition)
           (%client-notify
            conn
            (format nil "worktree open failed: ~A" condition))
           nil))))))

(defun %select-client-picker-item (session conn)
  (let* ((item (%picker-selected-item conn))
         (worktree (and item (%picker-item-worktree item)))
         (object
          (or worktree
              (and item
                   (or (nerimux/picker:picker-item-repository item)
                       (nerimux/picker:picker-item-organization item)))))
         (pane (%client-worktree-pane session worktree))
         (window (and pane (nerimux/pane:pane-window pane))))
    (cond
      ((and pane window)
       (nerimux/session:session-select-window session window)
       (nerimux/window:window-select-pane window pane)
       (%set-client-selected-worktree conn worktree)
       (%set-client-focus conn pane)
       (%close-client-picker conn)
       (%mark-dirty)
       t)
      (worktree
       (when (%open-client-worktree-pane session conn worktree)
         (%close-client-picker conn)
         t))
      (object
       (%set-client-selected-tree-object conn object)
       (%close-client-picker conn)
       (%client-notify conn
                       (typecase object
                         (nerimux/workspace-model:repository
                          "repository selected; use :wt-create --branch <branch> --confirm")
                         (nerimux/workspace-model:organization
                          "organization selected; select a repository first")))
       t)
      (t nil))))

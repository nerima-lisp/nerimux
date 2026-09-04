(in-package #:nerimux)

(defun %client-selected-status-file (conn)
  "Return the worktree and path represented by CONN's selected status row."
  (let ((object (%client-tree-object conn)))
    (when (and (consp object) (eq (first object) :file))
      (destructuring-bind (worktree-id path code) (rest object)
        (declare (ignore code))
        (let ((worktree (%workspace-find-worktree worktree-id)))
          (and worktree (list worktree path)))))))

(defun %client-run-status-write (conn repository operation args)
  "Run a status mutation through the asynchronous transient write path."
  (if (null repository)
      (%client-notify conn "no repository selected")
      (handler-case (%run-transient-git-write conn repository operation args)
        (error (condition)
          (%client-notify conn
                          (format nil
                                  "git ~(~A~): failed: ~A"
                                  operation
                                  condition)))))
  t)

(defun %client-stage-selection (conn)
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (%client-run-status-write
           conn
           (nerimux/workspace-model:worktree-repository worktree)
           :add
           (list "--" path)))
        (%client-notify conn "select a file first"))
    t))

(defun %client-stage-all (conn)
  (let ((worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%client-run-status-write
         conn
         (nerimux/workspace-model:worktree-repository worktree)
         :add
         (list "-A"))
        (%client-notify conn "no worktree selected"))
    t))

(defun %client-unstage-selection (conn)
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (%client-run-status-write
           conn
           (nerimux/workspace-model:worktree-repository worktree)
           :restore
           (list "--staged" "--" path)))
        (%client-notify conn "select a file first"))
    t))

(defun %client-unstage-all (conn)
  (let ((worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%client-run-status-write
         conn
         (nerimux/workspace-model:worktree-repository worktree)
         :restore
         (list "--staged" "--" "."))
        (%client-notify conn "no worktree selected"))
    t))

(defun %client-start-discard-selection (conn)
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (let ((repository
                  (nerimux/workspace-model:worktree-repository worktree)))
            (%open-confirm-view
             conn
             (format nil "git restore -- ~A" path)
             (list (cons "worktree"
                         (nerimux/workspace-model:worktree-path worktree))
                   (cons "path" path))
             (lambda ()
               (%client-run-status-write conn repository :restore
                                         (list "--" path))))
            t))
        (%client-notify conn "select a file first"))
    t))

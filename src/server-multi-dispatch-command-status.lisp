(in-package #:nerimux)

(defun %client-selected-status-file (conn)
  "Return the worktree and path represented by CONN's selected status row."
  (let ((object (%client-tree-object conn)))
    (when (and (consp object) (eq (first object) :file))
      (destructuring-bind (worktree-id path code &optional section) (rest object)
        (declare (ignore code section))
        (let ((worktree (%workspace-find-worktree worktree-id)))
          (and worktree (list worktree path)))))))

(defun %status-file-listed-p (files path)
  "True when PATH is one of FILES, a worktree's (CODE . PATH) change list."
  (and (member path files :key #'cdr :test #'equal) t))

(defun %status-file-staged-p (worktree path)
  (%status-file-listed-p (nerimux/workspace-model:worktree-staged-files worktree)
                         path))

(defun %status-file-untracked-p (worktree path)
  (%status-file-listed-p (nerimux/workspace-model:worktree-untracked-files
                          worktree)
                         path))

(defun %status-file-unstaged-p (worktree path)
  (or (%status-file-listed-p (nerimux/workspace-model:worktree-unstaged-files
                              worktree)
                             path)
      (%status-file-listed-p (nerimux/workspace-model:worktree-unmerged-files
                              worktree)
                             path)))

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
  (let* ((selection (%client-selected-status-file conn))
         (section (and selection (fifth (%client-tree-object conn)))))
    (if selection
        (destructuring-bind (worktree path) selection
          (cond
            ((eq section :staged)
             (%client-notify conn "already staged"))
            ((or (member section '(:unmerged :untracked :unstaged))
                 (null section))
             (if (and (null section)
                      (%status-file-staged-p worktree path)
                      (not (%status-file-unstaged-p worktree path))
                      (not (%status-file-untracked-p worktree path)))
                 (%client-notify conn "already staged")
                 (%client-run-status-write
                  conn
                  (nerimux/workspace-model:worktree-repository worktree)
                  :add
                  (list "--" path))))
            (t (%client-notify conn "select a file first"))))
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
  (let* ((selection (%client-selected-status-file conn))
         (section (and selection (fifth (%client-tree-object conn)))))
    (if selection
        (destructuring-bind (worktree path) selection
          (cond
            ((eq section :staged)
             (%client-run-status-write
              conn
              (nerimux/workspace-model:worktree-repository worktree)
              :restore
              (list "--staged" "--" path)))
            ((and (null section) (%status-file-staged-p worktree path))
             (%client-run-status-write
              conn
              (nerimux/workspace-model:worktree-repository worktree)
              :restore
              (list "--staged" "--" path)))
            (t (%client-notify conn "nothing to unstage"))))
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

(defun %discard-selection-write (worktree path &optional section)
  "Choose discard from the selected section; an unmerged row keeps its prior restore behavior."
  (cond
    ((eq section :untracked)
     (list :clean (list "-fd" "--" path)))
    ((eq section :staged)
     (list :restore (list "--staged" "--worktree" "--" path)))
    ((eq section :unstaged)
     (list :restore (list "--worktree" "--" path)))
    ((eq section :unmerged)
     (list :restore (list "--" path)))
    ((null section)
     (cond
       ((%status-file-untracked-p worktree path)
        (list :clean (list "-fd" "--" path)))
       ((%status-file-staged-p worktree path)
        (list :restore (list "--staged" "--worktree" "--" path)))
       (t (list :restore (list "--" path)))))
    (t (list :restore (list "--" path)))))

(defun %client-start-discard-selection (conn)
  (let* ((selection (%client-selected-status-file conn))
         (section (and selection (fifth (%client-tree-object conn)))))
    (if selection
        (destructuring-bind (worktree path) selection
          (let ((repository
                  (nerimux/workspace-model:worktree-repository worktree)))
            (destructuring-bind (operation args)
                (%discard-selection-write worktree path section)
              (%open-confirm-view
               conn
               (%transient-command-text operation args)
               (list (cons "worktree"
                           (nerimux/workspace-model:worktree-path worktree))
                     (cons "path" path))
               (lambda ()
                 (%client-run-status-write conn repository operation args))
               :clean-preview-args
               (when (eq operation :clean) (list "--" path))))
            t))
        (%client-notify conn "select a file first"))
    t))

(in-package #:nerimux/vcs)

(defstruct (%repository-refresh (:constructor %make-repository-refresh))
  (raw-worktrees nil :read-only t)
  (missing-p nil :read-only t)
  (status-updates nil :read-only t))

(defun %read-repository-refresh (repository)
  (multiple-value-bind (raw-worktrees missing-p)
      (%read-repository-worktrees repository)
    (%make-repository-refresh
     :raw-worktrees raw-worktrees
     :missing-p missing-p
     :status-updates
     (loop for raw in raw-worktrees
           unless (vcs-kit:vcs-worktree-bare-p raw)
             collect (%read-worktree-status-at
                      (vcs-kit:vcs-worktree-path raw)
                      (vcs-kit:vcs-worktree-head raw)
                      (nerimux/workspace-model:repository-local-path repository))))))

(defvar *worktree-refresh-successors* (make-hash-table :test #'eq :weakness :key))

(defun %refreshed-worktree-successor (worktree)
  (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
    (loop with seen = nil
          for current = worktree then successor
          for successor = (gethash current *worktree-refresh-successors*)
          do (when (member current seen :test #'eq) (return worktree))
             (push current seen)
          while successor
          unless (and (eq (nerimux/workspace-model:worktree-repository current)
                          (nerimux/workspace-model:worktree-repository successor))
                      (equal (nerimux/workspace-model:worktree-id current)
                             (nerimux/workspace-model:worktree-id successor))
                      (equal (nerimux/workspace-model:worktree-path current)
                             (nerimux/workspace-model:worktree-path successor)))
            do (return worktree)
          finally (return current))))

(defun %apply-repository-refresh (repository refresh)
  (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
  (let ((previous (copy-list (nerimux/workspace-model:repository-worktrees repository))))
    (%apply-repository-worktrees repository
                               (%repository-refresh-raw-worktrees refresh)
                               (%repository-refresh-missing-p refresh)
                               (%repository-refresh-status-updates refresh))
    (dolist (old previous)
      (let ((new (find (nerimux/workspace-model:worktree-path old)
                       (nerimux/workspace-model:repository-worktrees repository)
                       :key #'nerimux/workspace-model:worktree-path :test #'equal)))
        (when (and new (equal (nerimux/workspace-model:worktree-id old)
                              (nerimux/workspace-model:worktree-id new)))
          (setf (gethash old *worktree-refresh-successors*) new)))))
  (%apply-repository-status repository
                            (%repository-refresh-status-updates refresh)
                            (%repository-refresh-missing-p refresh))))
(defun refresh-repository-status (repository)
  "Refresh all statuses for REPOSITORY synchronously."
  (%apply-repository-status repository (%read-repository-status repository)))

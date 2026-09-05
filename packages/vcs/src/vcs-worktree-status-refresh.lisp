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

(defun %apply-repository-refresh (repository refresh)
  (%apply-repository-worktrees repository
                               (%repository-refresh-raw-worktrees refresh)
                               (%repository-refresh-missing-p refresh)
                               (%repository-refresh-status-updates refresh))
  (%apply-repository-status repository
                            (%repository-refresh-status-updates refresh)
                            (%repository-refresh-missing-p refresh)))

(defun refresh-repository-status (repository)
  "Refresh all statuses for REPOSITORY synchronously."
  (%apply-repository-status repository (%read-repository-status repository)))

(in-package #:nerimux/pane)

(defun worktree-attention-reasons (worktree)
  (when worktree
    (let ((reasons nil))
      (when (worktree-conflict-p worktree)
        (push :conflict reasons))
      (when (worktree-dirty-p worktree)
        (push :dirty reasons))
      (when (plusp (worktree-ahead worktree))
        (push :ahead reasons))
      (when (plusp (worktree-behind worktree))
        (push :behind reasons))
      (when (worktree-missing-p worktree)
        (push :missing reasons))
      (when (some #'pane-attention-p (worktree-panes worktree))
        (push :pane reasons))
      (nreverse reasons))))

(defun organization-attention-worktrees (organization)
  (loop for repository in (organization-repositories organization)
        append (remove-if-not #'worktree-attention-p
                              (repository-worktrees repository))))

(defun organization-recompute-counts (organization)
  (let ((worktrees
          (loop for repository in (organization-repositories organization)
                append (copy-list (repository-worktrees repository)))))
    (setf (organization-missing-p organization)
          (some #'repository-missing-p
                (organization-repositories organization))
          (organization-active-worktree-count organization)
          (count-if (lambda (worktree)
                      (not (worktree-missing-p worktree)))
                    worktrees)
          (organization-attention-count organization)
          (count-if #'worktree-attention-p worktrees)
          (organization-counts-derived-p organization) t))
  organization)

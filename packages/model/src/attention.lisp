(in-package #:nerimux/pane)

(defun %pane-escalates-to-worktree-p (pane)
  "T when PANE's state should pull its worktree into Attention.
   Unread output alone does not (WT-16 / RL-15): a pane the user is not looking
   at printing to its screen is a marker on that row, not work the worktree is
   waiting on.  PANE-ATTENTION-REASONS keeps the unread signal for the row."
  (some (lambda (reason) (not (eq reason :unread-output)))
        (pane-attention-reasons pane)))

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
      (when (nerimux/workspace-model:worktree-waiting-p worktree)
        (push :waiting reasons))
      (when (some #'%pane-escalates-to-worktree-p (worktree-panes worktree))
        (push :pane reasons))
      (nreverse reasons))))

(defun repository-attention-p (repository)
  "T when REPOSITORY itself, or any worktree under it, needs attention."
  (or (repository-dirty-p repository)
      (repository-conflict-p repository)
      (plusp (repository-ahead repository))
      (plusp (repository-behind repository))
      (repository-missing-p repository)
      (some #'worktree-attention-p (repository-worktrees repository))))

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

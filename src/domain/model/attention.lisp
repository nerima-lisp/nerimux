(in-package #:nerimux/model)

;;; ── Worktree/organization attention, composed from pane state ──────────────
;;;
;;; Loaded after pane-core.lisp (see nerimux.asd) specifically so this file,
;;; not worktree.lisp, is the one place a pane's attention state feeds into
;;; worktree- and organization-level attention. worktree.lisp keeps only ghq
;;; facts (conflict/dirty/ahead/behind/missing); it must never regain a
;;; reference to pane-attention-p or any other pane symbol (W3).

(defun worktree-attention-reasons (worktree)
  (when worktree
    (let ((reasons nil))
      (when (worktree-conflict-p worktree) (push :conflict reasons))
      (when (worktree-dirty-p worktree) (push :dirty reasons))
      (when (plusp (worktree-ahead worktree)) (push :ahead reasons))
      (when (plusp (worktree-behind worktree)) (push :behind reasons))
      (when (worktree-missing-p worktree) (push :missing reasons))
      (when (some #'pane-attention-p (worktree-panes worktree))
        (push :pane reasons))
      (nreverse reasons))))

(defun organization-attention-worktrees (organization)
  (loop for repository in (organization-repositories organization)
        append (remove-if-not #'worktree-attention-p
                              (repository-worktrees repository))))

(defun organization-recompute-counts (organization)
  ;; APPEND over copies, never MAPCAN: MAPCAN nconcs the repositories' own
  ;; worktree lists in place, and once an organization holds two repositories
  ;; a second recompute closes that shared tail into a cycle, hanging every
  ;; later traversal (the workspace scan spins at 100% CPU forever).
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

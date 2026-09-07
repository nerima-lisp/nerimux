(in-package #:nerimux/renderer)

(defun %workspace-worktree-node-expanded-p (worktree expanded-node-ids)
  (and expanded-node-ids
       (gethash (%workspace-tree-node-key worktree) expanded-node-ids)
       t))

(defun %workspace-worktree-pane-child-entries (worktree level)
  "One LEVEL entry per WORKTREE pane, ordered by PANE-ID for a stable,
   deterministic row order -- WORKTREE-PANES itself is insertion order
   (WORKTREE-ADD-PANE pushes), which would otherwise read newest-first."
  (loop for pane in (sort (copy-list (worktree-panes worktree))
                          #'<
                          :key
                          #'pane-id)
        collect (list level (%pane-tree-label pane) pane :pane)))

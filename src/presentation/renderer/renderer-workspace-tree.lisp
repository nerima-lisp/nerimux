(in-package #:nerimux/renderer)

;;;; Workspace tree projection: stable node identities, labels, attention,
;;;; refresh state, and organization -> repository -> worktree -> window ->
;;;; pane flattening. Both the plain ANSI workspace renderer and the
;;;; cl-tui-kit tree consume this projection.

(defun %repository-attention-p (repository)
  "T when REPOSITORY itself, or any worktree under it, needs attention."
  (or (repository-dirty-p repository)
      (repository-conflict-p repository)
      (plusp (repository-ahead repository))
      (plusp (repository-behind repository))
      (repository-missing-p repository)
      (some #'worktree-attention-p (repository-worktrees repository))))

(defun %worktree-tree-windows (worktree)
  "Distinct windows holding at least one of WORKTREE's panes, ordered by
   window id -- the order the tree and status line show them in (R5.8)."
  (sort (remove-duplicates (mapcar #'pane-window (worktree-panes worktree))
                           :test #'eq)
        #'< :key #'window-id))

(defun %workspace-tree-node-key (node)
  "Stable, EQUAL-comparable identity for a tree row, across all 5 levels
   (R6.3). Used both for tree-widget selection and, at the organization and
   repository levels, as the collapse-state table's key."
  (typecase node
    (organization (list :organization (organization-id node)))
    (repository (list :repository (repository-id node)))
    (worktree (list :worktree (worktree-id node)))
    (window (list :window (window-id node)))
    (pane (list :pane (window-id (pane-window node)) (pane-id node)))
    (t (list :workspace-object node))))

(defun %workspace-node-expanded-p (kind id expanded-node-ids)
  "T when the (KIND ID) organization/repository row is expanded in
   EXPANDED-NODE-IDS (a hash-table of tree-node keys -> T, or NIL). Absent
   means collapsed -- the tree's default state (R6.3: only organization rows
   show at first). Worktree/window/pane rows have no collapse state of their
   own; once their repository ancestor is expanded, all of them show."
  (and expanded-node-ids (gethash (list kind id) expanded-node-ids)))

(defun %organization-tree-label (organization)
  (let ((host (organization-host organization))
        (name (organization-name organization)))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t (organization-id organization)))))

(defun %repository-tree-label (repository)
  (or (and (plusp (length (repository-specification repository)))
           (repository-specification repository))
      (and (plusp (length (repository-local-path repository)))
           (repository-local-path repository))
      (repository-id repository)))

(defun %worktree-tree-label (worktree)
  (let ((branch (worktree-branch worktree))
        (path (worktree-path worktree)))
    (or (when (and branch (plusp (length branch))) branch)
        (and (plusp (length path)) path)
        (worktree-id worktree))))

(defun %window-tree-label (window)
  "WINDOW's tree-row label: id + name. NAME is already branch + sequence
   number (R5.8, computed once at window-creation time in
   workspace-window.lisp) -- this only formats it, it does not recompute it."
  (format nil "win ~D:~A" (window-id window) (window-name window)))

(defun %pane-tree-label (pane)
  (format nil "pane/~D ~A"
          (pane-id pane)
          (or (and (plusp (length (pane-title pane))) (pane-title pane))
              (and (plusp (length (pane-start-command pane)))
                   (pane-start-command pane))
              "shell")))

(defun %workspace-tree-node-attention-p (object kind)
  "T when OBJECT (a KIND tree node) should carry the `!` attention mark."
  (case kind
    (:organization (or (plusp (organization-attention-count object))
                        (organization-attention-worktrees object)))
    (:repository (%repository-attention-p object))
    (:worktree (worktree-attention-p object))
    (:pane (pane-attention-p object))
    (t nil)))

(defun %workspace-node-refresh-tag (kind id refreshing-ids stale-ids)
  "Return the refresh-state suffix for an organization, repository, or worktree."
  (let ((key (list kind id)))
    (cond
      ((and refreshing-ids (gethash key refreshing-ids)) " refreshing")
      ((and stale-ids (gethash key stale-ids)) " stale")
      (t ""))))

(defun workspace-tree-objects (organizations expanded-node-ids)
  "The objects the tree currently shows, in display order (R6.3)."
  (mapcar #'third (%workspace-flat-tree-entries organizations expanded-node-ids)))

(defun %workspace-flat-tree-entries
    (organizations expanded-node-ids &key refreshing-ids stale-ids)
  "Flatten ORGANIZATIONS into (LEVEL LABEL OBJECT KIND) display tuples."
  (let (entries)
    (dolist (organization organizations)
      (push (list 0
                  (concatenate
                   'string (%organization-tree-label organization)
                   (%workspace-node-refresh-tag
                    :organization (organization-id organization)
                    refreshing-ids stale-ids))
                  organization :organization)
            entries)
      (when (%workspace-node-expanded-p
             :organization (organization-id organization) expanded-node-ids)
        (dolist (repository (organization-repositories organization))
          (push (list 1
                      (concatenate
                       'string (%repository-tree-label repository)
                       (%workspace-node-refresh-tag
                        :repository (repository-id repository)
                        refreshing-ids stale-ids))
                      repository :repository)
                entries)
          (when (%workspace-node-expanded-p
                 :repository (repository-id repository) expanded-node-ids)
            (dolist (worktree (repository-worktrees repository))
              (push (list 2
                          (concatenate
                           'string (%worktree-tree-label worktree)
                           (%workspace-node-refresh-tag
                            :worktree (worktree-id worktree)
                            refreshing-ids stale-ids))
                          worktree :worktree)
                    entries)
              (dolist (window (%worktree-tree-windows worktree))
                (push (list 3 (%window-tree-label window) window :window) entries)
                (dolist (pane (window-panes window))
                  (push (list 4 (%pane-tree-label pane) pane :pane) entries))))))))
    (nreverse entries)))

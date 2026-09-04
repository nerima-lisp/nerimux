(in-package #:nerimux/vcs)

(defun %dispatch-callback (callback-dispatch callback &rest arguments)
  (when callback
    (if callback-dispatch
        (funcall callback-dispatch
                 (lambda ()
                   (apply callback arguments)))
        (apply callback arguments))))

(defun refresh-workspace-organizations-async (&key query
                                                   on-catalog
                                                   on-complete
                                                   on-error
                                                   on-repository-error
                                                   on-progress
                                                   callback-dispatch)
  "Refresh and store the workspace catalog on a worker thread.
   ON-CATALOG, when given, is called with the organizations as soon as the
   scan itself completes — before the per-repository status refresh, which
   runs `git status` across every repository and can take seconds on a large
   root.  ON-COMPLETE still fires only after the statuses; a UI caller uses
   ON-CATALOG to paint the freshly scanned tree instead of holding the
   \"scanning...\" placeholder until every status has arrived. ON-PROGRESS
   (FR-004b), when given, is called with the running repository count as the
   scan discovers each ghq entry -- before ON-CATALOG, and well before
   ON-COMPLETE's status pass.

ON-ERROR and ON-REPOSITORY-ERROR are two distinct failure channels, not one
(R6.2/design §7.3, FAILED-object-only staleness): ON-ERROR fires only for a
terminal scan failure (SCAN-REPOSITORIES-ASYNC's own ON-ERROR below, e.g.
`ghq list` itself failing) -- there is no catalog and no further callback
coming, so the whole refresh has failed. ON-REPOSITORY-ERROR fires once per
repository whose own `git status` failed during REFRESH-WORKSPACE-STATUS-
ASYNC below, called with (REPOSITORY CONDITION) exactly as REFRESH-
REPOSITORIES-ASYNC's own ON-ERROR is -- ON-COMPLETE still fires afterward
for the batch as a whole, since one repository's failure does not stop the
others from settling. Conflating the two used to mean a single repository's
status failure looked identical to a scan-wide failure to every caller,
which is what let a per-repository failure mark the ENTIRE catalog stale."
  (scan-repositories-async :query
                           query
                           :callback-dispatch
                           callback-dispatch
                           :on-progress
                           on-progress
                           :on-complete
                           (lambda (organizations)
                             (set-workspace-organizations organizations)
                             (when on-catalog
                               (funcall on-catalog organizations))
                             (refresh-workspace-status-async :organizations
                                                             organizations
                                                             :callback-dispatch
                                                             callback-dispatch
                                                             :on-complete
                                                             on-complete
                                                             :on-error
                                                             (lambda 
                                                                 (repository
                                                                  condition)
                                                               (when 
                                                                   on-repository-error
                                                                 (funcall
                                                                  on-repository-error
                                                                  repository
                                                                  condition)))))
                           :on-error
                           on-error))

(defun scan-repositories (&key query on-complete on-error on-progress)
  "Build the organization/repository hierarchy from ghq-list-repositories.
   ON-PROGRESS (FR-004b), when given, is called once per ghq entry with the
   running count of entries processed so far -- so a caller on a worker
   thread's other end can show \"N found\" while a large ghq root is still
   being walked, instead of only a bare scanning indicator."
  (handler-case
      (let ((organizations (make-hash-table :test #'equal))
            (processed 0))
        (dolist (entry (vcs-kit:ghq-list-repositories :query query))
          (multiple-value-bind (candidate repository)
              (%repository-from-entry entry)
            (let* ((key (nerimux/workspace-model:organization-id candidate))
                   (organization
                     (or (gethash key organizations)
                         (setf (gethash key organizations) candidate))))
              (nerimux/workspace-model:organization-add-repository
               organization repository)
              (handler-case
                  (list-repository-worktrees repository)
                (error ()
                  (setf (nerimux/workspace-model:repository-missing-p repository) t)))))
          (incf processed)
          (when on-progress (funcall on-progress processed)))
        (let ((result
                (sort (loop for organization being the hash-values of organizations
                            collect organization)
                      #'string<
                      :key #'nerimux/workspace-model:organization-id)))
          (when on-complete
            (funcall on-complete result))
          result))
    (error (condition)
      (if on-error
          (progn
            (funcall on-error condition)
            nil)
          (error condition)))))

(defun %make-vcs-repository (directory)
  (vcs-kit:make-vcs-repository directory))

(defun %read-repository-worktrees (repository)
  (let ((backend-repository
         (%make-vcs-repository
          (nerimux/workspace-model:repository-local-path repository))))
    (values (vcs-kit:vcs-list-worktrees backend-repository)
            (%path-missing-p
             (nerimux/workspace-model:repository-local-path repository)))))

(defun %apply-repository-worktrees
    (repository raw-worktrees missing-p &optional status-updates)
  (let ((previous (copy-list (nerimux/workspace-model:repository-worktrees repository))))
    (setf (nerimux/workspace-model:repository-missing-p repository) missing-p)
    (dolist (old-worktree previous)
      (dolist (pane (nerimux/workspace-model:worktree-panes old-worktree))
        (setf (nerimux/pane:pane-worktree pane) nil)))
    (setf (nerimux/workspace-model:repository-worktrees repository) nil
          (nerimux/workspace-model:repository-main-worktree repository) nil)
    (dolist (raw raw-worktrees)
      (let* ((path (vcs-kit:vcs-worktree-path raw))
             (status-update
               (find path status-updates
                     :key #'%worktree-status-update-path
                     :test #'string=))
             (old-worktree (find path previous
                                  :key #'nerimux/workspace-model:worktree-path
                                  :test #'string=))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id (and old-worktree
                         (nerimux/workspace-model:worktree-id old-worktree))
                :repository repository
                :path path
                :branch (vcs-kit:vcs-worktree-branch raw)
                :head (vcs-kit:vcs-worktree-head raw)
                :status (and old-worktree
                             (nerimux/workspace-model:worktree-status old-worktree))
                :panes (and old-worktree
                            (nerimux/workspace-model:worktree-panes old-worktree))
                :dirty-p (and old-worktree
                              (nerimux/workspace-model:worktree-dirty-p old-worktree))
                :conflict-p (and old-worktree
                                 (nerimux/workspace-model:worktree-conflict-p old-worktree))
                :ahead (if old-worktree
                           (nerimux/workspace-model:worktree-ahead old-worktree)
                           0)
                :behind (if old-worktree
                            (nerimux/workspace-model:worktree-behind old-worktree)
                            0)
                :changed-files (and old-worktree
                                    (nerimux/workspace-model:worktree-changed-files
                                     old-worktree))
                :staged-files (and old-worktree
                                   (nerimux/workspace-model:worktree-staged-files
                                    old-worktree))
                :unstaged-files (and old-worktree
                                     (nerimux/workspace-model:worktree-unstaged-files
                                      old-worktree))
                :untracked-files (and old-worktree
                                      (nerimux/workspace-model:worktree-untracked-files
                                       old-worktree))
                :unmerged-files (and old-worktree
                                     (nerimux/workspace-model:worktree-unmerged-files
                                      old-worktree))
                :recent-commits (and old-worktree
                                     (nerimux/workspace-model:worktree-recent-commits
                                      old-worktree))
                :commits-state (and old-worktree
                                    (nerimux/workspace-model:worktree-commits-state
                                     old-worktree))
                :stashes (and old-worktree
                              (nerimux/workspace-model:worktree-stashes old-worktree))
                :stashes-state (and old-worktree
                                    (nerimux/workspace-model:worktree-stashes-state
                                     old-worktree))
                :bare-p (vcs-kit:vcs-worktree-bare-p raw)
                :locked-p (vcs-kit:vcs-worktree-locked-p raw)
                :prunable-p (vcs-kit:vcs-worktree-prunable-p raw)
                :missing-p (if status-update
                               (%worktree-status-update-missing-p status-update)
                               (%path-missing-p path)))))
        (dolist (pane (nerimux/workspace-model:worktree-panes worktree))
          (setf (nerimux/pane:pane-worktree pane) worktree))
        (nerimux/workspace-model:repository-add-worktree repository worktree)))
    repository))

(defun list-repository-worktrees (repository)
  "Refresh REPOSITORY's worktree list from vcs-list-worktrees."
  (multiple-value-call #'%apply-repository-worktrees
    repository
    (%read-repository-worktrees repository)))

(defun %read-repository-status (repository)
  (loop for worktree in (nerimux/workspace-model:repository-worktrees
                         repository)
        unless (nerimux/workspace-model:worktree-bare-p worktree)
          collect (%read-worktree-status worktree)))

(defun %apply-repository-status (repository updates
                                            &optional
                                            (missing-p nil missing-p-p))
  (mapc
   (lambda (update)
     (%apply-worktree-status repository update))
   updates)
  (setf (nerimux/workspace-model:repository-missing-p repository) (if missing-p-p
                                                                      missing-p
                                                                      (%path-missing-p
                                                                       (nerimux/workspace-model:repository-local-path
                                                                        repository))))
  (nerimux/workspace-model:repository-recompute-status repository)
  repository)

(defun worktree-status (worktree)
  "Refresh WORKTREE status from vcs-status-structured."
  (let ((repository (nerimux/workspace-model:worktree-repository worktree)))
    (%apply-worktree-status repository (%read-worktree-status worktree))
    (when repository
      (setf (nerimux/workspace-model:repository-missing-p repository) (%path-missing-p
                                                                       (nerimux/workspace-model:repository-local-path
                                                                        repository)))
      (nerimux/workspace-model:repository-recompute-status repository))
    worktree))


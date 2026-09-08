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
                                                   on-start
                                                   on-repository-start
                                                   on-repository
                                                   callback-dispatch)
  "Refresh and store the workspace catalog on a worker thread.
   Only the latest registered request publishes a catalog or invokes observers.
   Registration happens under the catalog lock before scanning starts.
   Delivery checks the generation under the catalog lock."
  (let ((generation (gensym "CATALOG-")))
    (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
      (setf *workspace-catalog-generation* generation))
    (labels ((current-p ()
               (eq generation *workspace-catalog-generation*))
             (guard-observer (observer)
               (when observer
                 (lambda (&rest arguments)
                   (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
                     (when (current-p)
                       (apply observer arguments)))))))
      (scan-repositories-async
       :query query
       :on-start (guard-observer on-start)
       :callback-dispatch callback-dispatch
       :on-progress (guard-observer on-progress)
       :on-complete
       (lambda (organizations)
         (when (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
                 (when (current-p)
                   (set-workspace-organizations organizations)
                   (when on-catalog
                     (funcall on-catalog organizations))
                   (current-p)))
           (refresh-workspace-status-async
            :organizations organizations
            :on-start (guard-observer on-repository-start)
            :on-repository (guard-observer on-repository)
            :callback-dispatch callback-dispatch
            :on-complete (guard-observer on-complete)
            :on-error
            (guard-observer
             (lambda (repository condition)
               (when on-repository-error
                 (funcall on-repository-error repository condition)))))))
       :on-error (guard-observer on-error)))))

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
                :completed-p (and old-worktree
                                  (nerimux/workspace-model:worktree-completed-p old-worktree))
                :agent-pane (and old-worktree
                                 (nerimux/workspace-model:worktree-agent-pane old-worktree))
                :waiting-p (and old-worktree
                                (nerimux/workspace-model:worktree-waiting-p old-worktree))
                :waiting-time (and old-worktree
                                   (nerimux/workspace-model:worktree-waiting-time old-worktree))
                :waiting-message (and old-worktree
                                      (nerimux/workspace-model:worktree-waiting-message
                                       old-worktree))
                :waiting-host-notified-p (and old-worktree
                                             (nerimux/workspace-model:worktree-waiting-host-notified-p
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

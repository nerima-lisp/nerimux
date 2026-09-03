(in-package #:nerimux/workspace-model)

(defstruct (worktree
            (:constructor %make-worktree
                (&key id repository path branch head status panes dirty-p
                      conflict-p ahead behind bare-p locked-p prunable-p
                      missing-p changed-files recent-commits commits-state
                      staged-files unstaged-files untracked-files
                      unmerged-files stashes stashes-state)))
  (id "" :type string)
  (repository nil)
  (path "" :type string)
  (branch nil)
  (head nil)
  (status nil)
  (panes nil :type list)
  (dirty-p nil :type boolean)
  (conflict-p nil :type boolean)
  (ahead 0 :type integer)
  (behind 0 :type integer)
  (bare-p nil :type boolean)
  (locked-p nil :type boolean)
  (prunable-p nil :type boolean)
  (missing-p nil :type boolean)
  (changed-files nil :type list)
  (recent-commits nil :type list)
  (commits-state nil)
  (staged-files nil :type list)
  (unstaged-files nil :type list)
  (untracked-files nil :type list)
  (unmerged-files nil :type list)
  (stashes nil :type list)
  (stashes-state nil))

(defun worktree-key (path branch head)
  (format nil
          "~A|~A|~A"
          (%model-string path)
          (%model-string branch)
          (%model-string head)))

(defun make-worktree (&key id
                           repository
                           path
                           branch
                           head
                           status
                           panes
                           dirty-p
                           conflict-p
                           (ahead 0)
                           (behind 0)
                           bare-p
                           locked-p
                           prunable-p
                           missing-p
                           changed-files
                           recent-commits
                           commits-state
                           staged-files
                           unstaged-files
                           untracked-files
                           unmerged-files
                           stashes
                           stashes-state)
  (let ((path-string (%model-string path)))
    (%make-worktree :id
                    (or id (worktree-key path-string branch head))
                    :repository
                    repository
                    :path
                    path-string
                    :branch
                    branch
                    :head
                    head
                    :status
                    status
                    :panes
                    (copy-list panes)
                    :dirty-p
                    (not (null dirty-p))
                    :conflict-p
                    (not (null conflict-p))
                    :ahead
                    ahead
                    :behind
                    behind
                    :bare-p
                    (not (null bare-p))
                    :locked-p
                    (not (null locked-p))
                    :prunable-p
                    (not (null prunable-p))
                    :missing-p
                    (not (null missing-p))
                    :changed-files
                    (copy-list changed-files)
                    :recent-commits
                    (copy-list recent-commits)
                    :commits-state
                    commits-state
                    :staged-files
                    (copy-list staged-files)
                    :unstaged-files
                    (copy-list unstaged-files)
                    :untracked-files
                    (copy-list untracked-files)
                    :unmerged-files
                    (copy-list unmerged-files)
                    :stashes
                    (copy-list stashes)
                    :stashes-state
                    stashes-state)))

(defun worktree-attention-p (worktree)
  (not (null (nerimux/pane:worktree-attention-reasons worktree))))

(defun %organization-counts-explicit-p (organization)
  (and (not (organization-counts-derived-p organization))
       (or (organization-missing-p organization)
           (plusp (organization-active-worktree-count organization))
           (plusp (organization-attention-count organization)))))

(defun repository-recompute-status (repository)
  (let ((worktrees (repository-worktrees repository)))
    (setf (repository-dirty-p repository) (some #'worktree-dirty-p worktrees)
          (repository-conflict-p repository) (some #'worktree-conflict-p
                                                   worktrees)
          (repository-ahead repository) (if (repository-main-worktree
                                             repository)
                                            (worktree-ahead
                                             (repository-main-worktree
                                              repository))
                                            0)
          (repository-behind repository) (if (repository-main-worktree
                                              repository)
                                             (worktree-behind
                                              (repository-main-worktree
                                               repository))
                                             0))
    (when 
        (and (repository-organization repository)
             (not
              (%organization-counts-explicit-p
               (repository-organization repository))))
      (nerimux/pane:organization-recompute-counts
       (repository-organization repository))))
  repository)

(defun organization-add-repository (organization repository)
  (when (and organization repository)
    (pushnew repository (organization-repositories organization) :test #'eq)
    (setf (repository-organization repository) organization)
    (when (organization-counts-derived-p organization)
      (nerimux/pane:organization-recompute-counts organization)))
  repository)

(defun %repository-status-populated-p (repository)
  (or (repository-dirty-p repository)
      (repository-conflict-p repository)
      (not (zerop (repository-ahead repository)))
      (not (zerop (repository-behind repository)))))

(defun repository-add-worktree (repository worktree)
  (when (and repository worktree)
    (let ((status-populated-p (%repository-status-populated-p repository)))
      (pushnew worktree (repository-worktrees repository) :test #'eq)
      (setf (worktree-repository worktree) repository)
      (unless (repository-main-worktree repository)
        (setf (repository-main-worktree repository) worktree))
      (unless status-populated-p
        (repository-recompute-status repository))
      (let ((organization (repository-organization repository)))
        (when 
            (and organization
                 (not (%organization-counts-explicit-p organization)))
          (nerimux/pane:organization-recompute-counts organization)))))
  worktree)

(defun repository-worktree-by-path (repository path)
  (find (%model-string path)
        (repository-worktrees repository)
        :key
        #'worktree-path
        :test
        #'string=))

(in-package #:nerimux/workspace-model)

(defstruct (worktree
            (:constructor %make-worktree
                (&key id repository path branch head status panes dirty-p
                      conflict-p ahead behind locked-p prunable-p
                      missing-p
                      ((:read-error-p %read-error-p) nil)
                      ((:status-state %status-state) :unloaded)
                      ((:status-error-message %status-error-message) nil)
                      changed-files additions deletions numstat-state
                      numstat-error-message recent-commits commits-state
                      staged-files unstaged-files untracked-files
                      unmerged-files stashes stashes-state stashes-error-message
                      completed-p agent-pane waiting-p waiting-time waiting-message
                      waiting-host-notified-p)))
  (id "" :type string)
  (repository nil)
  (path "" :type string)
  (branch nil)
  (head nil)
  (status nil)
  (%status-state :unloaded
                 :type (member :unloaded :loading :ready :read-error :stale))
  (%status-error-message nil)
  (panes nil :type list)
  (completed-p nil :type boolean)
  (agent-pane nil)
  (dirty-p nil :type boolean)
  (conflict-p nil :type boolean)
  (ahead 0 :type integer)
  (behind 0 :type integer)
  (locked-p nil :type boolean)
  (prunable-p nil :type boolean)
  (missing-p nil :type boolean)
  (%read-error-p nil :type boolean)
  (changed-files nil :type list)
  (additions 0 :type integer)
  (deletions 0 :type integer)
  (numstat-state :unloaded :type (member :unloaded :ready :failed))
  (numstat-error-message nil)
  (recent-commits nil :type list)
  (commits-state nil)
  (staged-files nil :type list)
  (unstaged-files nil :type list)
  (untracked-files nil :type list)
  (unmerged-files nil :type list)
  (stashes nil :type list)
  (stashes-state nil)
  (stashes-error-message nil)
  (waiting-p nil :type boolean)
  (waiting-time nil)
  (waiting-message "" :type string)
  (waiting-host-notified-p t :type boolean))

(defun worktree-key (path branch head)
  (format nil
          "~A|~A|~A"
          (%model-string path)
          (%model-string branch)
          (%model-string head)))
(progn
  (defun worktree-status-state (worktree)
    (worktree-%status-state worktree))
  (defun worktree-status-error-message (worktree)
    (worktree-%status-error-message worktree))
  (defun worktree-read-error-p (worktree)
    (worktree-%read-error-p worktree))
  (defun worktree-transition-status (worktree state
                                    &key snapshot (snapshot-supplied-p nil)
                                      (error-message nil error-message-supplied-p))
    (case state
      (:unloaded
       (setf (worktree-status worktree) nil
             (worktree-%status-state worktree) :unloaded
             (worktree-%status-error-message worktree) nil
             (worktree-%read-error-p worktree) nil))
      (:loading
       (when snapshot-supplied-p
         (setf (worktree-status worktree) snapshot))
       (when error-message-supplied-p
         (setf (worktree-%status-error-message worktree) error-message))
       (setf (worktree-%status-state worktree) :loading)
       (when error-message
         (setf (worktree-%read-error-p worktree) t)))
      (:ready
       (when snapshot-supplied-p
         (setf (worktree-status worktree) snapshot))
       (setf (worktree-%status-state worktree) :ready
             (worktree-%status-error-message worktree) nil
             (worktree-%read-error-p worktree) nil))
      ((:read-error :stale)
       (setf (worktree-%status-state worktree)
             (if (worktree-status worktree) :stale :read-error)
             (worktree-%status-error-message worktree) error-message
             (worktree-%read-error-p worktree) t))
      (otherwise
       (error "Invalid worktree status state: ~S" state)))
    worktree))

(defun make-worktree (&key id
                           repository
                           path
                           branch
                           head
                           (status nil status-supplied-p)
                           (status-state nil status-state-supplied-p)
                           (status-error-message nil)
                           panes
                           dirty-p
                           conflict-p
                           (ahead 0)
                           (behind 0)
                           locked-p
                           prunable-p
                           missing-p
                           (read-error-p nil read-error-p-supplied-p)
                           changed-files
                           (additions 0)
                           (deletions 0)
                           (numstat-state :unloaded)
                           numstat-error-message
                           recent-commits
                           commits-state
                           staged-files
                           unstaged-files
                           untracked-files
                           unmerged-files
                           stashes
                           stashes-state
                           stashes-error-message
                           completed-p
                           agent-pane
                           waiting-p
                           waiting-time
                           waiting-message
                           waiting-host-notified-p)
  (let* ((path-string (%model-string path))
         (initial-status-state
           (if status-state-supplied-p
               status-state
               (cond ((and read-error-p-supplied-p read-error-p) :read-error)
                     (status :ready)
                     (t :unloaded))))
         (initial-read-error-p
           (if read-error-p-supplied-p
               (not (null read-error-p))
               (not
                (null
                 (or (member initial-status-state (list :read-error :stale)
                             :test (lambda (left right) (eq left right)))
                     (and (eq initial-status-state :loading)
                          status-error-message))))))
         (worktree
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
                           :status-state
                           initial-status-state
                           :status-error-message
                           status-error-message
                           :panes
                           (copy-list panes)
                           :completed-p
                           (not (null completed-p))
                           :agent-pane
                           agent-pane
                           :dirty-p
                           (not (null dirty-p))
                           :conflict-p
                           (not (null conflict-p))
                           :ahead
                           ahead
                           :behind
                           behind
                           :locked-p
                           (not (null locked-p))
                           :prunable-p
                           (not (null prunable-p))
                           :missing-p
                           (not (null missing-p))
                           :read-error-p
                           initial-read-error-p
                           :changed-files
                           (copy-list changed-files)
                           :additions
                           additions
                           :deletions
                           deletions
                           :numstat-state
                           numstat-state
                           :numstat-error-message
                           numstat-error-message
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
                           stashes-state
                           :stashes-error-message
                           stashes-error-message
                           :waiting-p
                           (not (null waiting-p))
                           :waiting-time
                           waiting-time
                           :waiting-message
                           (or waiting-message "")
                           :waiting-host-notified-p
                           (if (null waiting-host-notified-p)
                               (not waiting-p)
                               waiting-host-notified-p))))
    (worktree-transition-status worktree
                                initial-status-state
                                :snapshot status
                                :snapshot-supplied-p status-supplied-p
                                :error-message status-error-message)))

(defun worktree-mark-waiting (worktree message &optional (now (get-universal-time)))
  (when worktree
    (setf (worktree-waiting-p worktree) t
          (worktree-waiting-time worktree) now
          (worktree-waiting-message worktree) (if (stringp message)
                                                   message
                                                   (princ-to-string message))
          (worktree-waiting-host-notified-p worktree) nil))
  worktree)

(defun worktree-clear-waiting (worktree)
  (when worktree
    (setf (worktree-waiting-p worktree) nil
          (worktree-waiting-time worktree) nil
          (worktree-waiting-message worktree) ""
          (worktree-waiting-host-notified-p worktree) t))
  worktree)

(defun worktree-mark-waiting-host-notified (worktree)
  (when worktree
    (setf (worktree-waiting-host-notified-p worktree) t))
  worktree)

(defun worktree-complete (worktree)
  (setf (worktree-completed-p worktree) t)
  worktree)

(defun worktree-prune-classification (worktree)
  "Classify WORKTREE's snapshot for prune review, not deletion authorization."
  (let* ((repository (worktree-repository worktree))
         (primary (and repository (repository-main-worktree repository))))
    (cond
      ((null repository)
       (values :excluded :missing-repository))
      ((and primary
            (or (eq primary worktree)
                (string= (worktree-path primary) (worktree-path worktree))))
       (values :excluded :primary))
      ((worktree-locked-p worktree)
       (values :excluded :locked))
      ((or (some #'nerimux/pane:pane-live-p (worktree-panes worktree))
           (nerimux/pane:pane-live-p (worktree-agent-pane worktree)))
       (values :excluded :live-pane))
      ((worktree-read-error-p worktree)
       (values :excluded :read-error))
      ;; A worktree whose directory is gone holds no work to lose, so it is
      ;; repairable whether or not its agent ever reported completion.
      ((worktree-missing-p worktree)
       (values :missing :metadata-repair-required))
      ((and (not (worktree-completed-p worktree))
            (not (eq :exited (nerimux/pane:worktree-agent-state worktree))))
       (values :excluded :not-completed-or-agent-exited))
      ((or (worktree-dirty-p worktree) (worktree-conflict-p worktree))
       (values :candidate :confirmation-required))
      (t (values :candidate :clean)))))

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

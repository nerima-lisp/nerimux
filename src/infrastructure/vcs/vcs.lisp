(in-package #:nerimux/vcs)

(defun vcs-package-available-p ()
  (not (null (find-package :vcs-kit))))

(defun %string-value (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defun %specification-parts (specification)
  (let ((parts nil)
        (start 0)
        (string (%string-value specification)))
    (loop for end = (position #\/ string :start start)
          do (push (subseq string start end) parts)
          if end
            do (setf start (1+ end))
          else
            do (return))
    (remove-if (lambda (part) (zerop (length part))) (nreverse parts))))

(defun %organization-and-name (specification)
  (let ((parts (%specification-parts specification)))
    (cond
      ((>= (length parts) 3)
       (values (first parts) (second parts)))
      ((= (length parts) 2)
       (values "local" (first parts)))
      ((= (length parts) 1)
       (values "local" "default"))
      (t
       (values "local" "default")))))

(defun %repository-from-entry (entry)
  (let* ((specification
           (%string-value
            (vcs-kit:ghq-repository-entry-specification entry)))
         (path (%string-value (vcs-kit:ghq-repository-entry-path entry)))
         (backend (vcs-kit:ghq-repository-entry-backend entry))
         (host nil)
         (name nil))
    (multiple-value-setq (host name)
      (%organization-and-name specification))
    (values
     (nerimux/model:make-organization
      :id (nerimux/model:organization-key host name)
      :host host
      :name name)
     (nerimux/model:make-repository
      :specification specification
      :local-path path
      :backend (or backend :git)))))

(declaim (ftype function list-repository-worktrees))

(defvar *workspace-organizations* nil)

(defun workspace-organizations ()
  "Return the latest workspace catalog used by the global picker."
  (copy-list *workspace-organizations*))

(defun %catalog-worktrees (organizations)
  (loop for organization in organizations
        append (loop for repository in
                         (nerimux/model:organization-repositories organization)
                     append (copy-list
                             (nerimux/model:repository-worktrees repository)))))

(defun %worktree-association-match-p (id path worktree)
  (or (and (stringp id)
           (plusp (length id))
           (string= id (nerimux/model:worktree-id worktree)))
      (and (stringp path)
           (plusp (length path))
           (string= path (nerimux/model:worktree-path worktree)))))

(defun %remember-pane-associations (organizations)
  (loop for worktree in (%catalog-worktrees organizations)
        append (loop for pane in (nerimux/model:worktree-panes worktree)
                     collect (list (nerimux/model:worktree-id worktree)
                                   (nerimux/model:worktree-path worktree)
                                   pane))))

(defun %preserve-pane-associations (previous current)
  (let ((worktrees (%catalog-worktrees current)))
    (dolist (record (%remember-pane-associations previous))
      (destructuring-bind (id path pane) record
        (let ((worktree
                (find-if (lambda (candidate)
                           (%worktree-association-match-p id path candidate))
                         worktrees)))
          (if worktree
              (nerimux/model:worktree-add-pane worktree pane)
              (setf (nerimux/model:pane-worktree pane) nil))))))
  current)

(defun set-workspace-organizations (organizations)
  "Replace the workspace catalog with ORGANIZATIONS."
  (check-type organizations list)
  (let ((previous *workspace-organizations*)
        (current (copy-list organizations)))
    (setf *workspace-organizations* current)
    (%preserve-pane-associations previous current)))

(defun %dispatch-callback (callback-dispatch callback &rest arguments)
  (when callback
    (if callback-dispatch
        (funcall callback-dispatch
                 (lambda () (apply callback arguments)))
        (apply callback arguments))))

(defun refresh-workspace-organizations-async
    (&key query on-catalog on-complete on-error callback-dispatch)
  "Refresh and store the workspace catalog on a worker thread.
   ON-CATALOG, when given, is called with the organizations as soon as the
   scan itself completes — before the per-repository status refresh, which
   runs `git status` across every repository and can take seconds on a large
   root.  ON-COMPLETE still fires only after the statuses; a UI caller uses
   ON-CATALOG to paint the freshly scanned tree instead of holding the
   \"scanning...\" placeholder until every status has arrived."
  (scan-repositories-async
   :query query
   :callback-dispatch callback-dispatch
   :on-complete (lambda (organizations)
                  (set-workspace-organizations organizations)
                  (when on-catalog
                    (funcall on-catalog organizations))
                  (refresh-workspace-status-async
                   :organizations organizations
                   :callback-dispatch callback-dispatch
                   :on-complete on-complete
                   :on-error (lambda (repository condition)
                               (declare (ignore repository))
                               (when on-error
                                 (funcall on-error condition)))))
   :on-error on-error))

(defun scan-repositories (&key query on-complete on-error)
  "Build the organization/repository hierarchy from ghq-list-repositories."
  (handler-case
      (let ((organizations (make-hash-table :test #'equal)))
        (dolist (entry (vcs-kit:ghq-list-repositories :query query))
          (multiple-value-bind (candidate repository)
              (%repository-from-entry entry)
            (let* ((key (nerimux/model:organization-id candidate))
                   (organization
                     (or (gethash key organizations)
                         (setf (gethash key organizations) candidate))))
              (nerimux/model:organization-add-repository
               organization repository)
              ;; One unreadable repository (a broken or half-deleted clone in
              ;; the ghq root) must not abort the scan: the enclosing
              ;; handler-case would blank the entire catalog with no message.
              ;; Keep the entry, mark it missing, move on.
              (handler-case
                  (list-repository-worktrees repository)
                (error ()
                  (setf (nerimux/model:repository-missing-p repository) t))))))
        (let ((result
                (sort (loop for organization being the hash-values of organizations
                            collect organization)
                      #'string<
                      :key #'nerimux/model:organization-id)))
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

(defun %path-missing-p (path)
  (and (stringp path)
       (plusp (length path))
       (null (probe-file path))))

(defun %read-repository-worktrees (repository)
  (let ((backend-repository
          (%make-vcs-repository (nerimux/model:repository-path repository))))
    (values (vcs-kit:vcs-list-worktrees backend-repository)
            (%path-missing-p (nerimux/model:repository-path repository)))))

(defstruct (%worktree-status-update
             (:constructor %make-worktree-status-update))
  (path nil :read-only t)
  (missing-p nil :read-only t)
  (snapshot nil :read-only t)
  (head nil :read-only t)
  (dirty-p nil :read-only t)
  (conflict-p nil :read-only t)
  (ahead nil :read-only t)
  (behind nil :read-only t))

(defun %apply-repository-worktrees
    (repository raw-worktrees missing-p &optional status-updates)
  (let ((previous (copy-list (nerimux/model:repository-worktrees repository))))
    (setf (nerimux/model:repository-missing-p repository) missing-p)
    (dolist (old-worktree previous)
      (dolist (pane (nerimux/model:worktree-panes old-worktree))
        (setf (nerimux/model:pane-worktree pane) nil)))
    (setf (nerimux/model:repository-worktrees repository) nil
          (nerimux/model:repository-main-worktree repository) nil)
    (dolist (raw raw-worktrees)
      (let* ((path (vcs-kit:vcs-worktree-path raw))
             (status-update
               (find path status-updates
                     :key #'%worktree-status-update-path
                     :test #'string=))
             (old-worktree (find path previous
                                  :key #'nerimux/model:worktree-path
                                  :test #'string=))
             (worktree
               (nerimux/model:make-worktree
                :id (and old-worktree
                         (nerimux/model:worktree-id old-worktree))
                :repository repository
                :path path
                :branch (vcs-kit:vcs-worktree-branch raw)
                :head (vcs-kit:vcs-worktree-head raw)
                :status (and old-worktree
                             (nerimux/model:worktree-status old-worktree))
                :panes (and old-worktree
                            (nerimux/model:worktree-panes old-worktree))
                :dirty-p (and old-worktree
                              (nerimux/model:worktree-dirty-p old-worktree))
                :conflict-p (and old-worktree
                                 (nerimux/model:worktree-conflict-p old-worktree))
                :ahead (if old-worktree
                           (nerimux/model:worktree-ahead old-worktree)
                           0)
                :behind (if old-worktree
                            (nerimux/model:worktree-behind old-worktree)
                            0)
                :bare-p (vcs-kit:vcs-worktree-bare-p raw)
                :locked-p (vcs-kit:vcs-worktree-locked-p raw)
                :prunable-p (vcs-kit:vcs-worktree-prunable-p raw)
                :missing-p (if status-update
                               (%worktree-status-update-missing-p status-update)
                               (%path-missing-p path)))))
        (dolist (pane (nerimux/model:worktree-panes worktree))
          (setf (nerimux/model:pane-worktree pane) worktree))
        (nerimux/model:repository-add-worktree repository worktree)))
    repository))

(defun list-repository-worktrees (repository)
  "Refresh REPOSITORY's worktree list from vcs-list-worktrees."
  (multiple-value-call #'%apply-repository-worktrees
    repository
    (%read-repository-worktrees repository)))

(defun %status-entry-conflict-p (entry)
  (eq (vcs-kit:vcs-status-entry-kind entry) :unmerged))

(defun %read-worktree-status-at (path fallback-head repository-path)
  (let* ((directory (if (plusp (length path)) path repository-path))
         (missing-p (and (stringp directory)
                         (plusp (length directory))
                         (null (probe-file directory)))))
    (if missing-p
        (%make-worktree-status-update
         :path path :missing-p t :head fallback-head :ahead 0 :behind 0)
        (let* ((snapshot
                 ;; This reads local remote-tracking refs. Only an explicit
                 ;; fetch advances them, so refresh never performs network I/O.
                 (vcs-kit:vcs-status-structured
                  (%make-vcs-repository directory)))
               (entries (vcs-kit:vcs-status-snapshot-entries snapshot))
               (branch-head
                 (vcs-kit:vcs-status-snapshot-branch-head snapshot)))
          (%make-worktree-status-update
           :path path :snapshot snapshot
           :head (or branch-head fallback-head)
           :dirty-p (not (null entries))
           :conflict-p (not (null (some #'%status-entry-conflict-p entries)))
           :ahead (or (vcs-kit:vcs-status-snapshot-ahead snapshot) 0)
           :behind (or (vcs-kit:vcs-status-snapshot-behind snapshot) 0))))))

(defun %read-worktree-status (worktree)
  (let ((repository (nerimux/model:worktree-repository worktree)))
    (%read-worktree-status-at
     (nerimux/model:worktree-path worktree)
     (nerimux/model:worktree-head worktree)
     (and repository (nerimux/model:repository-path repository)))))

(defun %apply-worktree-status (repository update)
  (let ((worktree
          (nerimux/model:repository-worktree-by-path
           repository (%worktree-status-update-path update))))
    (unless worktree
      (error "Status update refers to an unknown worktree: ~A"
             (%worktree-status-update-path update)))
    (setf (nerimux/model:worktree-missing-p worktree)
          (%worktree-status-update-missing-p update)
          (nerimux/model:worktree-status worktree)
          (%worktree-status-update-snapshot update)
          (nerimux/model:worktree-head worktree)
          (%worktree-status-update-head update)
          (nerimux/model:worktree-dirty-p worktree)
          (%worktree-status-update-dirty-p update)
          (nerimux/model:worktree-conflict-p worktree)
          (%worktree-status-update-conflict-p update)
          (nerimux/model:worktree-ahead worktree)
          (%worktree-status-update-ahead update)
          (nerimux/model:worktree-behind worktree)
          (%worktree-status-update-behind update))
    worktree))

(defun %read-repository-status (repository)
  (mapcar #'%read-worktree-status
          (nerimux/model:repository-worktrees repository)))

(defun %apply-repository-status
    (repository updates &optional (missing-p nil missing-p-p))
  (mapc (lambda (update) (%apply-worktree-status repository update)) updates)
  (setf (nerimux/model:repository-missing-p repository)
        (if missing-p-p
            missing-p
            (%path-missing-p (nerimux/model:repository-path repository))))
  (nerimux/model:repository-recompute-status repository)
  repository)

(defstruct (%repository-refresh
             (:constructor %make-repository-refresh))
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
     (mapcar
      (lambda (raw)
        (%read-worktree-status-at
         (vcs-kit:vcs-worktree-path raw)
         (vcs-kit:vcs-worktree-head raw)
         (nerimux/model:repository-path repository)))
      raw-worktrees))))

(defun %apply-repository-refresh (repository refresh)
  (%apply-repository-worktrees
   repository
   (%repository-refresh-raw-worktrees refresh)
   (%repository-refresh-missing-p refresh)
   (%repository-refresh-status-updates refresh))
  (%apply-repository-status
   repository
   (%repository-refresh-status-updates refresh)
   (%repository-refresh-missing-p refresh)))

(defun worktree-status (worktree)
  "Refresh WORKTREE status from vcs-status-structured."
  (let ((repository (nerimux/model:worktree-repository worktree)))
    (%apply-worktree-status repository (%read-worktree-status worktree))
    (when repository
      (setf (nerimux/model:repository-missing-p repository)
            (%path-missing-p (nerimux/model:repository-path repository)))
      (nerimux/model:repository-recompute-status repository))
    worktree))

(defun refresh-repository-status (repository)
  "Refresh all statuses for REPOSITORY synchronously."
  (%apply-repository-status repository (%read-repository-status repository)))

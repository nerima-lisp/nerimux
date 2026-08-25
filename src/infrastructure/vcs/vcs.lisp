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

(defun refresh-workspace-organizations (&key query on-complete on-error)
  "Refresh and store the workspace catalog synchronously."
  (handler-case
      (let ((organizations (scan-repositories :query query)))
        (set-workspace-organizations organizations)
        (dolist (repository
                  (loop for organization in organizations
                        append (nerimux/model:organization-repositories
                                organization)))
          (refresh-repository-status repository))
        (when on-complete
          (funcall on-complete organizations))
        organizations)
    (error (condition)
      (if on-error
          (progn
            (funcall on-error condition)
            nil)
          (error condition)))))

(defun refresh-workspace-organizations-async (&key query on-catalog on-complete
                                                on-error)
  "Refresh and store the workspace catalog on a worker thread.
   ON-CATALOG, when given, is called with the organizations as soon as the
   scan itself completes — before the per-repository status refresh, which
   runs `git status` across every repository and can take seconds on a large
   root.  ON-COMPLETE still fires only after the statuses; a UI caller uses
   ON-CATALOG to paint the freshly scanned tree instead of holding the
   \"scanning...\" placeholder until every status has arrived."
  (scan-repositories-async
   :query query
   :on-complete (lambda (organizations)
                  (set-workspace-organizations organizations)
                  (when on-catalog
                    (funcall on-catalog organizations))
                  (refresh-workspace-status-async
                   :organizations organizations
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

(defun list-repository-worktrees (repository)
  "Refresh REPOSITORY's worktree list from vcs-list-worktrees."
  (let* ((previous (copy-list (nerimux/model:repository-worktrees repository)))
         (backend-repository
         (%make-vcs-repository (nerimux/model:repository-path repository)))
         (raw-worktrees
           (vcs-kit:vcs-list-worktrees backend-repository)))
    (setf (nerimux/model:repository-missing-p repository)
          (%path-missing-p (nerimux/model:repository-path repository)))
    (dolist (old-worktree previous)
      (dolist (pane (nerimux/model:worktree-panes old-worktree))
        (setf (nerimux/model:pane-worktree pane) nil)))
    (setf (nerimux/model:repository-worktrees repository) nil
          (nerimux/model:repository-main-worktree repository) nil)
    (dolist (raw raw-worktrees)
      (let* ((path (vcs-kit:vcs-worktree-path raw))
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
                :missing-p (%path-missing-p path))))
        (dolist (pane (nerimux/model:worktree-panes worktree))
          (setf (nerimux/model:pane-worktree pane) worktree))
        (nerimux/model:repository-add-worktree repository worktree)))
    repository))

(defun %status-entry-conflict-p (entry)
  (eq (vcs-kit:vcs-status-entry-kind entry) :unmerged))

(defun worktree-status (worktree)
  "Refresh WORKTREE status from vcs-status-structured."
  (let* ((repository (nerimux/model:worktree-repository worktree))
         (worktree-path (nerimux/model:worktree-path worktree))
         (directory (if (plusp (length worktree-path))
                        worktree-path
                        (and repository
                             (nerimux/model:repository-path repository))))
         (missing-p (and (stringp directory)
                         (plusp (length directory))
                         (null (probe-file directory)))))
    (if missing-p
        (progn
          (setf (nerimux/model:worktree-missing-p worktree) t
                (nerimux/model:worktree-status worktree) nil
                (nerimux/model:worktree-dirty-p worktree) nil
                (nerimux/model:worktree-conflict-p worktree) nil
                (nerimux/model:worktree-ahead worktree) 0
                (nerimux/model:worktree-behind worktree) 0)
         (when repository
            (setf (nerimux/model:repository-missing-p repository)
                  (%path-missing-p (nerimux/model:repository-path repository)))
            (nerimux/model:repository-recompute-status repository))
          worktree)
        (let* ((backend-repository (%make-vcs-repository directory))
               ;; VCS-STATUS-STRUCTURED reads the local remote-tracking ref
               ;; (e.g. refs/remotes/origin/main), not the remote itself, so
               ;; AHEAD/BEHIND below are the divergence as of the last fetch,
               ;; not the live divergence from the remote right now (R7.5).
               ;; They only move when something updates that tracking ref —
               ;; in this codebase, only an explicit C-q F / C-q C-f
               ;; (FETCH-REPOSITORY / FETCH-ORGANIZATION-ASYNC below). No
               ;; automatic fetch runs before a status refresh (design
               ;; document §3.7 and §14).
               (snapshot (vcs-kit:vcs-status-structured backend-repository))
               (entries (vcs-kit:vcs-status-snapshot-entries snapshot))
               (branch-head
                 (vcs-kit:vcs-status-snapshot-branch-head snapshot))
               (ahead (vcs-kit:vcs-status-snapshot-ahead snapshot))
               (behind (vcs-kit:vcs-status-snapshot-behind snapshot)))
          (setf (nerimux/model:worktree-missing-p worktree) nil
                (nerimux/model:worktree-status worktree) snapshot
                (nerimux/model:worktree-head worktree)
                (if branch-head
                    branch-head
                    (nerimux/model:worktree-head worktree))
                (nerimux/model:worktree-dirty-p worktree) (not (null entries))
                (nerimux/model:worktree-conflict-p worktree)
                (not (null (some #'%status-entry-conflict-p entries)))
                (nerimux/model:worktree-ahead worktree) (or ahead 0)
                (nerimux/model:worktree-behind worktree) (or behind 0))
          (when repository
            (setf (nerimux/model:repository-missing-p repository)
                  (%path-missing-p (nerimux/model:repository-path repository)))
            (nerimux/model:repository-recompute-status repository))
          worktree))))

(defun refresh-repository-status (repository)
  "Refresh all statuses for REPOSITORY synchronously."
  (dolist (worktree (nerimux/model:repository-worktrees repository))
    (worktree-status worktree))
  (nerimux/model:repository-recompute-status repository)
  repository)

(defun scan-repositories-async (&key query on-complete on-error)
  "Run SCAN-REPOSITORIES on a worker thread and return its thread handle."
  (cl-concurrent-kit:make-thread
   (lambda ()
     (scan-repositories :query query
                        :on-complete on-complete
                        :on-error on-error))
   :name "nerimux-vcs-scan"))

(defun refresh-repositories-async
    (repositories &key on-repository on-complete on-error
                            (refresh-function #'refresh-repository-status))
  "Refresh each repository on its own worker and return all thread handles."
  (let* ((repositories (copy-list repositories))
         (remaining (cl-concurrent-kit:make-atomic-counter
                     (length repositories)))
         (threads nil))
    (labels ((complete-one ()
               (cl-concurrent-kit:atomic-counter-decf remaining)
               (when (zerop (cl-concurrent-kit:atomic-counter-value remaining))
                 (when on-complete
                   (funcall on-complete repositories)))))
      (if (null repositories)
          (progn
            (when on-complete
              (funcall on-complete repositories))
            nil)
          (progn
            (dolist (repository repositories (nreverse threads))
              (let ((current repository))
                (push
                 (cl-concurrent-kit:make-thread
                  (lambda ()
                    (unwind-protect
                         (handler-case
                             (progn
                               (funcall refresh-function current)
                               (when on-repository
                                 (funcall on-repository current))
                               current)
                           (error (condition)
                             (if on-error
                                 (progn
                                   (funcall on-error current condition)
                                   nil)
                                 (error condition))))
                      (complete-one)))
                  :name (format nil "nerimux-vcs-status-~A"
                                (nerimux/model:repository-id current)))
                 threads))))))))

(defun refresh-workspace-status-async
    (&key (organizations *workspace-organizations*) on-repository on-complete
          on-error (refresh-function #'refresh-repository-status))
  "Refresh all catalog repositories concurrently without blocking the UI."
  (refresh-repositories-async
   (loop for organization in organizations
         append (nerimux/model:organization-repositories organization))
   :on-repository on-repository
   :on-complete on-complete
   :on-error on-error
   :refresh-function refresh-function))

(defun %timestamp-token ()
  "Return the current local time as YYYYMMDDTHHMMSS, matching the
`date +%Y%m%dT%H%M%S` convention used for worktree directory names (R7.2)."
  (multiple-value-bind (second minute hour date month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0D"
            year month date hour minute second)))

(defun %ensure-trailing-slash (string)
  (if (and (plusp (length string))
           (char= (char string (1- (length string))) #\/))
      string
      (concatenate 'string string "/")))

(defun %worktree-path-candidate (repository-git-dir base-name suffix)
  (concatenate 'string repository-git-dir ".worktrees/" base-name
               (if suffix (format nil "-~D" suffix) "")))

(defun %unique-worktree-path (repository-git-dir base-name)
  "Return REPOSITORY-GIT-DIR/.worktrees/BASE-NAME, or that name with -2, -3,
... appended until a path that does not already exist is found (R7.2)."
  (let ((candidate (%worktree-path-candidate repository-git-dir base-name nil)))
    (if (null (probe-file candidate))
        candidate
        (loop for suffix from 2
              for numbered = (%worktree-path-candidate
                               repository-git-dir base-name suffix)
              when (null (probe-file numbered))
                return numbered))))

(defun %resolve-worktree-path (repository start-point-short-sha path)
  "Resolve the filesystem path for a new worktree.

PATH, when given, is used verbatim. Otherwise the path is fixed to
<repo>.git/.worktrees/<created-time>-<start-point-short-sha> (R7.2), with
-2, -3, ... appended if that name is already taken."
  (or (and path (%string-value path))
      (%unique-worktree-path
       (%ensure-trailing-slash
        (%string-value (nerimux/model:repository-path repository)))
       (format nil "~A-~A" (%timestamp-token) start-point-short-sha))))

(defun %repository-backend (repository)
  (%make-vcs-repository (nerimux/model:repository-path repository)))

(defun %rev-parse (repository &rest arguments)
  (apply #'vcs-kit:git-rev-parse-value (%repository-backend repository)
         arguments))

(defun %default-branch-start-point (repository)
  "Return the commit at REPOSITORY's default branch tip: the commit
refs/remotes/origin/HEAD currently points to (R7.3).

This is only as current as the last fetch (R7.5): call FETCH-REPOSITORY or
FETCH-REPOSITORY-ASYNC first if it needs to reflect the remote's latest
state."
  (%rev-parse repository "origin/HEAD"))

(defun %short-sha (repository commit)
  (%rev-parse repository "--short" commit))

(defun create-worktree
    (repository &key branch path start-point force)
  "Create a worktree with a new branch and refresh its repository model.

BRANCH names the new branch; git worktree add -b always creates it (R7.4),
there is no mode that attaches to an existing branch. START-POINT defaults to
REPOSITORY's default branch tip (R7.3) when not given."
  (unless (and repository branch (plusp (length (%string-value branch))))
    (error "A repository and non-empty branch are required to create a worktree."))
  (let* ((branch-name (%string-value branch))
         (resolved-start-point
           (or (and start-point (%string-value start-point))
               (%default-branch-start-point repository)))
         (worktree-path
           (%resolve-worktree-path
            repository (%short-sha repository resolved-start-point) path))
         (backend-repository (%repository-backend repository))
         (arguments
           (append (list "add")
                   (when force (list "--force"))
                   (list "-b" branch-name worktree-path resolved-start-point))))
    (apply #'vcs-kit:vcs-worktree backend-repository arguments)
    (list-repository-worktrees repository)
    (refresh-repository-status repository)
    (or (nerimux/model:repository-worktree-by-path repository worktree-path)
        (error "VCS created a worktree but it was not returned by list-worktrees: ~A"
               worktree-path))))

(defun delete-worktree (worktree &key force)
  "Remove WORKTREE after protecting the repository's primary checkout."
  (let* ((repository (and worktree (nerimux/model:worktree-repository worktree)))
         (main-worktree
           (and repository (nerimux/model:repository-main-worktree repository))))
    (unless (and worktree repository)
      (error "A repository worktree is required to delete a worktree."))
    (when (or (eq worktree main-worktree)
              (and main-worktree
                   (string= (nerimux/model:worktree-path worktree)
                            (nerimux/model:worktree-path main-worktree))))
      (error "The repository's primary worktree cannot be deleted."))
    (let ((backend-repository
            (%make-vcs-repository (nerimux/model:repository-path repository)))
          (arguments
            (append (list "remove")
                    (when force (list "--force"))
                    (list (nerimux/model:worktree-path worktree)))))
      (apply #'vcs-kit:vcs-worktree backend-repository arguments)
      (list-repository-worktrees repository)
      (refresh-repository-status repository)
      t)))

(defun lock-worktree (worktree &key reason)
  "Lock WORKTREE so prune and delete operations skip it until unlocked."
  (let ((repository (and worktree (nerimux/model:worktree-repository worktree))))
    (unless (and worktree repository)
      (error "A repository worktree is required to lock a worktree."))
    (let ((backend-repository
            (%make-vcs-repository (nerimux/model:repository-path repository)))
          (arguments
            (append (list "lock")
                    (when (and reason (plusp (length (%string-value reason))))
                      (list "--reason" (%string-value reason)))
                    (list (nerimux/model:worktree-path worktree)))))
      (apply #'vcs-kit:vcs-worktree backend-repository arguments)
      (list-repository-worktrees repository)
      (refresh-repository-status repository)
      t)))

(defun unlock-worktree (worktree)
  "Unlock WORKTREE, restoring it to prune and delete eligibility."
  (let ((repository (and worktree (nerimux/model:worktree-repository worktree))))
    (unless (and worktree repository)
      (error "A repository worktree is required to unlock a worktree."))
    (let ((backend-repository
            (%make-vcs-repository (nerimux/model:repository-path repository)))
          (arguments (list "unlock" (nerimux/model:worktree-path worktree))))
      (apply #'vcs-kit:vcs-worktree backend-repository arguments)
      (list-repository-worktrees repository)
      (refresh-repository-status repository)
      t)))

(defun prune-worktrees (repository &key (dry-run t) verbose)
  "Prune REPOSITORY's stale worktree administrative files.

When DRY-RUN is true (the default), git worktree prune --dry-run reports
what would be removed without mutating anything; callers must only pass a
false DRY-RUN once a user has explicitly confirmed the operation."
  (unless repository
    (error "A repository is required to prune worktrees."))
  (let* ((backend-repository
           (%make-vcs-repository (nerimux/model:repository-path repository)))
         (arguments
           (append (list "prune")
                   (when dry-run (list "--dry-run"))
                   (when verbose (list "--verbose"))))
         (result (apply #'vcs-kit:vcs-worktree backend-repository arguments)))
    (list-repository-worktrees repository)
    (refresh-repository-status repository)
    result))

(defun %run-vcs-operation-async (name thunk on-complete on-error)
  (cl-concurrent-kit:make-thread
   (lambda ()
     (handler-case
         (let ((result (funcall thunk)))
           (when on-complete
             (funcall on-complete result))
           result)
       (error (condition)
         (when on-error
           (funcall on-error condition))
         nil)))
   :name name))

(defun create-worktree-async
    (repository &key branch path start-point force on-complete on-error)
  "Create a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-create"
   (lambda ()
     (create-worktree repository
                      :branch branch
                      :path path
                      :start-point start-point
                      :force force))
   on-complete
   on-error))

(defun delete-worktree-async (worktree &key force on-complete on-error)
  "Delete a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-delete"
   (lambda () (delete-worktree worktree :force force))
   on-complete
   on-error))

(defun lock-worktree-async (worktree &key reason on-complete on-error)
  "Lock a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-lock"
   (lambda () (lock-worktree worktree :reason reason))
   on-complete
   on-error))

(defun unlock-worktree-async (worktree &key on-complete on-error)
  "Unlock a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-unlock"
   (lambda () (unlock-worktree worktree))
   on-complete
   on-error))

(defun prune-worktrees-async
    (repository &key (dry-run t) verbose on-complete on-error)
  "Prune a repository's worktrees on a worker thread and invoke one callback.

DRY-RUN defaults true, matching PRUNE-WORKTREES, so an omitted keyword here
stays non-destructive instead of silently forwarding a false DRY-RUN."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-prune"
   (lambda () (prune-worktrees repository :dry-run dry-run :verbose verbose))
   on-complete
   on-error))

;;; ── Explicit fetch (R7.1) ────────────────────────────────────────────────
;;;
;;; git fetch is never run implicitly (design document §14): the only
;;; producers are C-q F / C-q C-f, which land here. AHEAD/BEHIND therefore
;;; stay frozen between fetches (R7.5, see the comment in WORKTREE-STATUS).
;;;
;;; *IN-PROGRESS-FETCHES* suppresses a duplicate fetch for the same target
;;; while one is already running, keyed on (:repository repository-id) or
;;; (:organization organization-id) — the two independent things C-q F and
;;; C-q C-f can target. *FETCH-LOCK* guards it since worker threads and the
;;; server's own thread can race to begin or end a fetch.

(defvar *fetch-lock* (cl-concurrent-kit:make-lock :name "nerimux-vcs-fetch"))
(defvar *in-progress-fetches* (make-hash-table :test #'equal))

(defun %fetch-begin (key)
  "Mark KEY in progress and return T, unless it already was, in which case
return NIL without changing anything."
  (cl-concurrent-kit:with-lock-held (*fetch-lock*)
    (if (gethash key *in-progress-fetches*)
        nil
        (setf (gethash key *in-progress-fetches*) t))))

(defun %fetch-end (key)
  (cl-concurrent-kit:with-lock-held (*fetch-lock*)
    (remhash key *in-progress-fetches*)))

(defun fetch-repository (repository)
  "Fetch REPOSITORY's remotes with git fetch, then refresh its status."
  (unless repository
    (error "A repository is required to fetch."))
  (vcs-kit:vcs-fetch (%repository-backend repository))
  (refresh-repository-status repository)
  repository)

(defun fetch-repository-async (repository &key on-complete on-error)
  "Fetch REPOSITORY on a worker thread and invoke one callback.

Suppresses a duplicate fetch: a call made while REPOSITORY is already being
fetched invokes ON-COMPLETE immediately with NIL and starts no thread,
leaving the in-flight fetch's own callback as the one that reports the
result."
  (let ((key (list :repository (nerimux/model:repository-id repository))))
    (if (%fetch-begin key)
        (%run-vcs-operation-async
         "nerimux-vcs-repository-fetch"
         (lambda () (fetch-repository repository))
         (lambda (result)
           (%fetch-end key)
           (when on-complete (funcall on-complete result)))
         (lambda (condition)
           (%fetch-end key)
           (when on-error (funcall on-error condition))))
        (progn
          (when on-complete (funcall on-complete nil))
          nil))))

(defun fetch-organization-async (organization &key on-complete on-error)
  "Fetch every repository under ORGANIZATION concurrently, refreshing each
one's status, and invoke ON-COMPLETE once all of them finish.

Suppresses a duplicate fetch: a call made while ORGANIZATION is already being
fetched invokes ON-COMPLETE immediately with NIL and starts no threads."
  (let ((key (list :organization (nerimux/model:organization-id organization))))
    (if (%fetch-begin key)
        (refresh-repositories-async
         (nerimux/model:organization-repositories organization)
         :on-complete (lambda (repositories)
                        (%fetch-end key)
                        (when on-complete (funcall on-complete repositories)))
         :on-error on-error
         :refresh-function #'fetch-repository)
        (progn
          (when on-complete (funcall on-complete nil))
          nil))))

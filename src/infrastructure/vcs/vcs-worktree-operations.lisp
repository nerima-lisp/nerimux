(in-package #:nerimux/vcs)

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

(defun %run-vcs-operation-async
    (name worker apply-result on-complete on-error callback-dispatch)
  (cl-concurrent-kit:make-thread
   (lambda ()
     (handler-case
         (let ((worker-result (funcall worker)))
           (%dispatch-callback
            callback-dispatch
            (lambda ()
              (handler-case
                  (let ((result (funcall apply-result worker-result)))
                    (when on-complete
                      (funcall on-complete result)))
                (error (condition)
                  (when on-error
                    (funcall on-error condition))))))
           worker-result)
       (error (condition)
         (%dispatch-callback callback-dispatch on-error condition)
         nil)))
   :name name))

(defstruct (%worktree-operation-result
             (:constructor %make-worktree-operation-result))
  (repository nil :read-only t)
  (value nil :read-only t)
  (refresh nil :read-only t))

(defun %capture-worktree-operation-result (repository value)
  (%make-worktree-operation-result
   :repository repository
   :value value
   :refresh (%read-repository-refresh repository)))

(defun %apply-worktree-operation-result (operation-result)
  (%apply-repository-refresh
   (%worktree-operation-result-repository operation-result)
   (%worktree-operation-result-refresh operation-result))
  (%worktree-operation-result-value operation-result))

(defun %create-worktree-command (repository branch path start-point force)
  (unless (and repository branch (plusp (length (%string-value branch))))
    (error "A repository and non-empty branch are required to create a worktree."))
  (let* ((branch-name (%string-value branch))
         (resolved-start-point
           (or (and start-point (%string-value start-point))
               (%default-branch-start-point repository)))
         (worktree-path
           (%resolve-worktree-path
            repository (%short-sha repository resolved-start-point) path))
         (arguments
           (append (list "add")
                   (when force (list "--force"))
                   (list "-b" branch-name worktree-path resolved-start-point))))
    (apply #'vcs-kit:vcs-worktree (%repository-backend repository) arguments)
    worktree-path))

(defun %apply-created-worktree (repository operation-result)
  (let ((worktree-path
          (%apply-worktree-operation-result operation-result)))
    (or (nerimux/model:repository-worktree-by-path repository worktree-path)
        (error "VCS created a worktree but it was not returned by list-worktrees: ~A"
               worktree-path))))

(defun %worktree-operation-command (worktree operation &rest options)
  (let ((repository (and worktree (nerimux/model:worktree-repository worktree))))
    (unless (and worktree repository)
      (error "A repository worktree is required for this operation."))
    (apply #'vcs-kit:vcs-worktree
           (%repository-backend repository)
           (append (list operation)
                   (remove nil options)
                   (list (nerimux/model:worktree-path worktree))))
    repository))

(defun %delete-worktree-command (worktree force)
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
    (%worktree-operation-command
     worktree "remove" (when force "--force"))))

(defun %lock-worktree-command (worktree reason)
  (%worktree-operation-command
   worktree "lock"
   (when (and reason (plusp (length (%string-value reason)))) "--reason")
   (when (and reason (plusp (length (%string-value reason))))
     (%string-value reason))))

(defun %unlock-worktree-command (worktree)
  (%worktree-operation-command worktree "unlock"))

(defun %prune-worktrees-command (repository dry-run verbose)
  (unless repository
    (error "A repository is required to prune worktrees."))
  (let ((result
          (apply #'vcs-kit:vcs-worktree
                 (%repository-backend repository)
                 (append (list "prune")
                         (when dry-run (list "--dry-run"))
                         (when verbose (list "--verbose"))))))
    (list repository result)))

(defmacro define-worktree-async-operation
    (name lambda-list documentation thread-name command-form)
  `(defun ,name ,lambda-list
     ,documentation
     (%run-vcs-operation-async
      ,thread-name
      (lambda ()
        (let ((repository ,command-form))
          (%capture-worktree-operation-result repository t)))
      #'%apply-worktree-operation-result
      on-complete
      on-error
      callback-dispatch)))

(defun create-worktree-async
    (repository &key branch path start-point force on-complete on-error
                         callback-dispatch)
  "Create a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-create"
   (lambda ()
     (%capture-worktree-operation-result
      repository
      (%create-worktree-command repository branch path start-point force)))
   (lambda (operation-result)
     (%apply-created-worktree repository operation-result))
   on-complete
   on-error
   callback-dispatch))

(define-worktree-async-operation
    delete-worktree-async
    (worktree &key force on-complete on-error callback-dispatch)
    "Delete a worktree on a worker thread and invoke one callback."
    "nerimux-vcs-worktree-delete"
    (%delete-worktree-command worktree force))

(define-worktree-async-operation
    lock-worktree-async
    (worktree &key reason on-complete on-error callback-dispatch)
    "Lock a worktree on a worker thread and invoke one callback."
    "nerimux-vcs-worktree-lock"
    (%lock-worktree-command worktree reason))

(define-worktree-async-operation
    unlock-worktree-async
    (worktree &key on-complete on-error callback-dispatch)
    "Unlock a worktree on a worker thread and invoke one callback."
    "nerimux-vcs-worktree-unlock"
    (%unlock-worktree-command worktree))

(defun prune-worktrees-async
    (repository &key (dry-run t) verbose on-complete on-error callback-dispatch)
  "Prune a repository's worktrees on a worker thread and invoke one callback.

DRY-RUN defaults true, matching PRUNE-WORKTREES, so an omitted keyword here
stays non-destructive instead of silently forwarding a false DRY-RUN."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-prune"
   (lambda ()
     (let ((worker-result (%prune-worktrees-command repository dry-run verbose)))
       (%capture-worktree-operation-result
        (first worker-result) (second worker-result))))
   (lambda (operation-result)
     (%apply-worktree-operation-result operation-result))
   on-complete
   on-error
   callback-dispatch))

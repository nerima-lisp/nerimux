(in-package #:nerimux)

(defun %client-create-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "worktree create requires --confirm")
        t)
      (let* ((repository (%client-selected-repository conn target))
             (branch (or (%client-option-value args
                                               '("--branch" "-b" "branch"))
                         (%client-positional-branch args)))
             (path (%client-option-value args '("--path" "path")))
             (force (%client-boolean-option-p args '("--force" "force"))))
        (cond
          ((not repository)
           (%client-notify conn "worktree create requires a repository")
           t)
          ((not (and (stringp branch) (plusp (length branch))))
           (%client-notify conn "worktree create requires a branch")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (format nil "creating worktree ~A" branch))
           (handler-case
               (nerimux/vcs:create-worktree-async
                repository
                :branch branch
                :path path
                :force force
                :on-complete
                (lambda (worktree)
                  (when (%client-live-p conn)
                    (%set-client-selected-worktree conn worktree))
                  (%refresh-client-picker conn)
                  (%client-notify conn "worktree created")
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree create failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree create failed: ~A" condition))))
           t)))))

(defun %client-delete-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "worktree delete requires --confirm")
        t)
      (let ((worktree (%client-operation-worktree conn target))
            (force (%client-boolean-option-p args '("--force" "force"))))
        (cond
          ((not worktree)
           (%client-notify conn "worktree delete requires a worktree")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (format nil "deleting worktree ~A"
                    (nerimux/model:worktree-path worktree)))
           (handler-case
               (nerimux/vcs:delete-worktree-async
                worktree
                :force force
                :on-complete
                (lambda (ignored)
                  (declare (ignore ignored))
                  (when (and (%client-live-p conn)
                             (eq (client-conn-selected-worktree conn)
                                 worktree))
                    (setf (client-conn-selected-tree-object conn) nil
                          (client-conn-selected-worktree conn) nil))
                  (%refresh-client-picker conn)
                  (%client-notify conn "worktree deleted")
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree delete failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree delete failed: ~A" condition))))
           t)))))

(defun %client-lock-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "worktree lock requires --confirm")
        t)
      (let ((worktree (%client-operation-worktree conn target))
            (reason (%client-option-value args '("--reason" "reason"))))
        (cond
          ((not worktree)
           (%client-notify conn "worktree lock requires a worktree")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (format nil "locking worktree ~A"
                    (nerimux/model:worktree-path worktree)))
           (handler-case
               (nerimux/vcs:lock-worktree-async
                worktree
                :reason reason
                :on-complete
                (lambda (ignored)
                  (declare (ignore ignored))
                  (%refresh-client-picker conn)
                  (%client-notify conn "worktree locked")
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree lock failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree lock failed: ~A" condition))))
           t)))))

(defun %client-unlock-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "worktree unlock requires --confirm")
        t)
      (let ((worktree (%client-operation-worktree conn target)))
        (cond
          ((not worktree)
           (%client-notify conn "worktree unlock requires a worktree")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (format nil "unlocking worktree ~A"
                    (nerimux/model:worktree-path worktree)))
           (handler-case
               (nerimux/vcs:unlock-worktree-async
                worktree
                :on-complete
                (lambda (ignored)
                  (declare (ignore ignored))
                  (%refresh-client-picker conn)
                  (%client-notify conn "worktree unlocked")
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree unlock failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree unlock failed: ~A" condition))))
           t)))))

(defun %client-prune-worktrees (conn target args &key dry-run)
  "Preview or perform a git worktree prune for the target repository.

DRY-RUN must default true at every call site; a caller passes DRY-RUN NIL
only after the user has confirmed a previewed prune, and even then this
function still requires both an explicit --confirm option AND that a dry-run
preview was already shown to CONN for this same repository (tracked via
CLIENT-CONN-PENDING-PRUNE-PREVIEW-REPOSITORY-ID) — so a prune can never be
reached by a single accidental keystroke, a scripted --confirm with no
preview, or a preview of a different repository."
  (if (and (not dry-run)
           (not (%client-boolean-option-p args '("--confirm" "confirm"))))
      (progn
        (%client-notify conn "worktree prune requires --confirm")
        t)
      (let ((repository (%client-selected-repository conn target))
            (verbose (%client-boolean-option-p args '("--verbose" "verbose"))))
        (cond
          ((not repository)
           (%client-notify conn "worktree prune requires a repository")
           t)
          ((and (not dry-run)
                (not (equal (client-conn-pending-prune-preview-repository-id
                             conn)
                            (nerimux/model:repository-id repository))))
           (%client-notify
            conn
            "worktree prune requires a preview first: run wt-prune, then wt-prune-confirm --confirm")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (if dry-run "previewing worktree prune" "pruning worktrees"))
           (handler-case
               (nerimux/vcs:prune-worktrees-async
                repository
                :dry-run dry-run
                :verbose verbose
                :on-complete
                (lambda (output)
                  (setf (client-conn-pending-prune-preview-repository-id conn)
                        (and dry-run (nerimux/model:repository-id repository)))
                  (%refresh-client-picker conn)
                  (%client-notify
                   conn
                   (if dry-run
                       (format nil "worktree prune preview: ~A"
                               (if (and (stringp output) (plusp (length output)))
                                   output
                                   "nothing to prune"))
                       "worktrees pruned"))
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree prune failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree prune failed: ~A" condition))))
           t)))))



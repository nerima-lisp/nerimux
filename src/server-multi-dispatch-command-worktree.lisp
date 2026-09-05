(in-package #:nerimux)

(defun %client-delete-worktree (conn target args)
  (%with-client-confirmation (conn args "delete")
    (let ((worktree (%client-operation-worktree conn target))
          (force (%client-boolean-option-p args '("--force" "force"))))
        (cond
          ((not worktree)
            (%client-notify conn "worktree delete requires a worktree")
            t)
          ((not (nerimux/vcs:vcs-package-available-p))
            (%client-notify conn "VCS unavailable")
            t)
          (t
            (%client-notify conn
                            (format nil
                                    "deleting worktree ~A"
                                    (nerimux/workspace-model:worktree-path
                                     worktree)))
            (%mark-workspace-refreshing :worktree
                                        (nerimux/workspace-model:worktree-id
                                         worktree))
            (flet ((%on-error (condition)
                     (%clear-workspace-refreshing :worktree
                                                  (nerimux/workspace-model:worktree-id
                                                   worktree)
                                                  :stale-p
                                                  t)
                     (%client-notify conn
                                     (format nil
                                             "worktree delete failed: ~A"
                                             condition))
                     (%mark-dirty)))
              (handler-case (nerimux/vcs:delete-worktree-async worktree
                                                               :force
                                                               force
                                                               :callback-dispatch
                                                               #'%enqueue-main-thread-callback
                                                               :on-complete
                                                               (lambda (ignored)
                                                                 (declare (ignore
                                                                           ignored))
                                                                 (%clear-workspace-refreshing
                                                                  :worktree
                                                                  (nerimux/workspace-model:worktree-id
                                                                   worktree))
                                                                 (when 
                                                                     (and
                                                                      (%client-live-p
                                                                       conn)
                                                                      (eq
                                                                       (client-conn-selected-worktree
                                                                        conn)
                                                                       worktree))
                                                                   (setf (client-conn-selected-tree-object
                                                                          conn) nil
                                                                         (client-conn-selected-worktree
                                                                          conn) nil))
                                                                 (%refresh-client-picker
                                                                  conn)
                                                                 (%client-notify
                                                                  conn
                                                                  "worktree deleted")
                                                                 (%mark-dirty))
                                                               :on-error
                                                               #'%on-error)
                (error (condition)
                  (%on-error condition))))
            t)))))

(defmacro %define-worktree-state-operation
    (name operation command progressive complete &rest operation-arguments)
  `(defun ,name (conn target args)
     (%with-client-confirmation (conn args ,command)
       (let ((worktree (%client-operation-worktree conn target)))
         (cond
           ((not worktree)
            (%client-notify conn
                            (format nil "worktree ~A requires a worktree"
                                    ,command))
            t)
           ((not (nerimux/vcs:vcs-package-available-p))
            (%client-notify conn "VCS unavailable")
            t)
           (t
            (%client-notify conn
                            (format nil "~A worktree ~A"
                                    ,progressive
                                    (nerimux/workspace-model:worktree-path
                                     worktree)))
            (%mark-workspace-refreshing
             :worktree
             (nerimux/workspace-model:worktree-id worktree))
            (flet ((%on-error (condition)
                     (%clear-workspace-refreshing
                      :worktree
                      (nerimux/workspace-model:worktree-id worktree)
                      :stale-p
                      t)
                     (%client-notify
                      conn
                      (format nil "worktree ~A failed: ~A"
                              ,command
                              condition))
                     (%mark-dirty)))
              (handler-case
                  (,operation worktree
                              ,@operation-arguments
                              :callback-dispatch
                              #'%enqueue-main-thread-callback
                              :on-complete
                              (lambda (ignored)
                                (declare (ignore ignored))
                                (%clear-workspace-refreshing
                                 :worktree
                                 (nerimux/workspace-model:worktree-id
                                  worktree))
                                (%refresh-client-picker conn)
                                (%client-notify
                                 conn
                                 (format nil "worktree ~A" ,complete))
                                (%mark-dirty))
                              :on-error
                              #'%on-error)
                (error (condition)
                  (%on-error condition))))
            t))))))

(%define-worktree-state-operation
 %client-lock-worktree
 nerimux/vcs:lock-worktree-async
 "lock"
 "locking"
 "locked"
 :reason
 (%client-option-value args '("--reason" "reason")))

(%define-worktree-state-operation
 %client-unlock-worktree
 nerimux/vcs:unlock-worktree-async
 "unlock"
 "unlocking"
 "unlocked")

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
                (not
                 (equal (client-conn-pending-prune-preview-repository-id conn)
                        (nerimux/workspace-model:repository-id repository))))
            (%client-notify conn
                            "worktree prune requires a preview first: run wt-prune, then wt-prune-confirm --confirm")
            t)
          ((not (nerimux/vcs:vcs-package-available-p))
          (%client-notify conn "VCS unavailable")
            t)
          (t
            (%client-notify conn
                            (if dry-run
                                "previewing worktree prune"
                                "pruning worktrees"))
            (%mark-workspace-refreshing :repository
                                        (nerimux/workspace-model:repository-id
                                         repository))
            (flet ((%on-error (condition)
                     (%clear-workspace-refreshing :repository
                                                  (nerimux/workspace-model:repository-id
                                                   repository)
                                                  :stale-p
                                                  t)
                     (%client-notify conn
                                     (format nil
                                             "worktree prune failed: ~A"
                                             condition))
                     (%mark-dirty)))
              (handler-case (nerimux/vcs:prune-worktrees-async repository
                                                               :dry-run
                                                               dry-run
                                                               :verbose
                                                               verbose
                                                               :callback-dispatch
                                                               #'%enqueue-main-thread-callback
                                                               :on-complete
                                                               (lambda (output)
                                                                 (%clear-workspace-refreshing
                                                                  :repository
                                                                  (nerimux/workspace-model:repository-id
                                                                   repository))
                                                                 (setf (client-conn-pending-prune-preview-repository-id
                                                                        conn) (and
                                                                               dry-run
                                                                               (nerimux/workspace-model:repository-id
                                                                                repository)))
                                                                 (%refresh-client-picker
                                                                  conn)
                                                                 (%client-notify
                                                                  conn
                                                                  (if dry-run
                                                                      (format
                                                                       nil
                                                                       "worktree prune preview: ~A"
                                                                       (if (and
                                                                            (stringp
                                                                             output)
                                                                            (plusp
                                                                             (length
                                                                              output)))
                                                                           output
                                                                           "nothing to prune"))
                                                                      "worktrees pruned"))
                                                                 (%mark-dirty))
                                                               :on-error
                                                               #'%on-error)
                (error (condition)
                  (%on-error condition))))
            t)))))

(in-package #:nerimux)

(defun %client-create-worktree-now (repository branch
                                               conn
                                               session
                                               &key
                                               path
                                               force)
  "Create a worktree and select it when the asynchronous operation completes."
  (%client-notify conn (format nil "creating worktree ~A" branch))
  (%mark-workspace-refreshing :repository
                              (nerimux/workspace-model:repository-id repository))
  (flet ((%on-error (condition)
           (%clear-workspace-refreshing :repository
                                        (nerimux/workspace-model:repository-id
                                         repository)
                                        :stale-p t)
           (%client-notify conn
                           (format nil "worktree create failed: ~A" condition))
           (%mark-dirty)))
    (handler-case
        (nerimux/vcs:create-worktree-async
         repository :branch branch :path path :force force
         :callback-dispatch #'%enqueue-main-thread-callback
         :on-complete
         (lambda (worktree)
           (%clear-workspace-refreshing
            :repository (nerimux/workspace-model:repository-id repository))
           (when (%client-live-p conn)
             (%set-client-selected-worktree conn worktree)
             (when session
               (%focus-selected-client-worktree session conn)))
           (%refresh-client-picker conn)
           (%client-notify conn "worktree created")
           (%mark-dirty))
         :on-error #'%on-error)
      (error (condition)
        (%on-error condition))))
  t)

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
           (%client-notify conn "VCS unavailable")
           t)
          (t
           (%client-create-worktree-now
            repository branch conn (%attach-target-session)
            :path path :force force))))))

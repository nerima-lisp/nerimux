(in-package #:nerimux)

(defun %worktree-display-path (path)
  "PATH with the ghq root elided (PC-11).  The root is the same for every
   worktree here, so spending the width on it is what pushes the part that
   says which worktree was created off the message line."
  (let ((root (and (stringp path)
                   (string-right-trim "/" (or (nerimux/vcs:ghq-root-directory) "")))))
    (if (and root
             (plusp (length root))
             (> (length path) (1+ (length root)))
             (string= root path :end2 (length root)))
        (subseq path (1+ (length root)))
        path)))

(defun %client-create-worktree-now (repository branch
                                               conn
                                               session
                                               &key
                                               path
                                               force)
  (let ((display-branch (%strip-argument-control-characters branch)))
  (%client-notify conn (format nil "creating worktree ~A" display-branch))
  (%mark-workspace-refreshing :repository
                              (nerimux/workspace-model:repository-id repository))
  (let ((job (%workspace-job-begin :repository (repository-id repository) :create repository)))
  (flet ((%on-error (condition)
           (%workspace-job-update job repository :failed :outcome condition)
           (%clear-workspace-refreshing :repository
                                        (nerimux/workspace-model:repository-id
                                         repository)
                                        :stale-p
                                        t)
           (%client-log-process conn
                                (format nil "git worktree add -b ~A" display-branch)
                                nil
                                (princ-to-string condition))
           (%client-notify conn
                           (format nil "worktree create failed: ~A" condition))
           (%mark-dirty)))
    (handler-case (nerimux/vcs:create-worktree-async repository
                                                     :branch
                                                     branch
                                                     :path
                                                     path
                                                     :force
                                                     force
                                                     :callback-dispatch
                                                     #'%enqueue-main-thread-callback
                                                     :on-start
                                                     (lambda () (%workspace-job-update job repository :running))
                                                     :on-complete
                                                     (lambda (worktree)
                                                       (%workspace-job-update job repository :succeeded)
                                                       (%clear-workspace-refreshing
                                                        :repository
                                                        (nerimux/workspace-model:repository-id
                                                         repository))
                                                       (when
                                                           (%client-live-p conn)
                                                         (%set-client-selected-worktree
                                                          conn
                                                          worktree)
                                                         (%note-worktree-layout
                                                          conn repository
                                                          (nerimux/workspace-model:worktree-path
                                                           worktree))
                                                         (when session
                                                           (%open-client-worktree-pane
                                                            session
                                                            conn
                                                            worktree)))
                                                       (%refresh-client-picker
                                                        conn)
                                                       (%client-log-process
                                                        conn
                                                        (format nil "git worktree add -b ~A ~A"
                                                                display-branch
                                                                (nerimux/workspace-model:worktree-path
                                                                 worktree))
                                                        t
                                                        "")
                                                       (%client-notify
                                                        conn
                                                        (format nil "worktree created: ~A"
                                                                (%worktree-display-path
                                                                 (nerimux/workspace-model:worktree-path
                                                                  worktree))))
                                                       (%mark-dirty))
                                                     :on-error
                                                     #'%on-error)
      (error (condition)
        (%on-error condition))))))
  t)

(defun %worktree-path-escapes-repository-p (repository path)
  "True when the explicit --path value PATH could place a worktree outside
   REPOSITORY's own tree (CWE-22): a `..` component walks out from any base
   directory, and an absolute path is only accepted once it already sits
   under the directory %WORKTREE-PARENT-DIRECTORY would have chosen for it."
  (or (member ".." (uiop:split-string path :separator '(#\/)) :test #'string=)
      (and (plusp (length path))
           (char= (char path 0) #\/)
           (let ((parent (string-right-trim
                          "/"
                          (nerimux/vcs:worktree-parent-directory repository))))
             (not (and (>= (length path) (length parent))
                       (string= parent path :end2 (length parent))))))))

(defun %client-create-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "wt-create: add --confirm to run")
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
          ((%dash-leading-name-p branch)
           (%client-notify conn "a name cannot start with -")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS unavailable")
           t)
          ((and (stringp path) (%dash-leading-name-p path))
           (%client-notify conn "a path cannot start with -")
           t)
          ((and (stringp path) (%worktree-path-escapes-repository-p repository path))
           (%client-notify conn "path must stay under the repository")
           t)
          (t
           (%client-create-worktree-now
            repository branch conn (%attach-target-session)
            :path path :force force))))))

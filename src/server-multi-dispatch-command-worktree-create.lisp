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
(defun %client-branch-display-text (branch)
  (remove-if
   (lambda (character)
     (let ((code (char-code character)))
       (or (< code 32) (= code 127) (<= 128 code 159))))
   (%strip-argument-control-characters branch)))
(defun %client-branch-picker-items (candidates)
  (loop for candidate in candidates
        for kind = (getf candidate :kind)
        for branch = (%client-branch-display-text
                      (if (eq :remote kind)
                          (format nil "~A/~A"
                                  (getf candidate :remote)
                                  (getf candidate :branch))
                          (getf candidate :branch)))
        for label = (format nil "~A ~A~A"
                            (if (eq :remote kind) "remote" "local")
                            branch
                            (if (getf candidate :worktree)
                                " [in worktree]"
                                ""))
        for index from 0
        collect (nerimux/picker:make-picker-item
                 :id (format nil "branch/~D" index)
                 :kind :branch
                 :label label
                 :data candidate)))
(defun %client-branch-candidate-ref (candidate)
  (if (eq :remote (getf candidate :kind))
      (format nil "~A/~A"
              (getf candidate :remote)
              (getf candidate :branch))
      (getf candidate :branch)))
(defun %client-start-worktree-branch-picker (session conn)
  (let ((repository (%client-selected-repository conn)))
    (cond
      ((null repository)
       (%client-notify conn "select a repository first"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS unavailable"))
      ((%open-client-picker conn :mode :branch :repository repository)
       (nerimux/vcs:list-worktree-branch-candidates-async
        repository
        :callback-dispatch #'%enqueue-main-thread-callback
        :on-complete
        (lambda (candidates)
          (when (and (%client-live-p conn)
                     (eq :branch (client-conn-picker-mode conn))
                     (eq repository (client-conn-picker-repository conn)))
            (setf (client-conn-picker-items conn)
                  (%client-branch-picker-items candidates))
            (%picker-clamp-index conn (%client-picker-visible-items conn))
            (%mark-dirty)))
        :on-error
        (lambda (condition)
          (declare (ignore condition))
          (when (and (%client-live-p conn)
                     (eq :branch (client-conn-picker-mode conn))
                     (eq repository (client-conn-picker-repository conn)))
            (setf (client-conn-picker-items conn) nil)
            (%client-notify conn "branch list failed")
            (%mark-dirty))))
       t)
      (t nil))))

(defun %client-create-worktree-now (repository branch
                                               conn
                                               session
                                               &key
                                               path
                                               force)
  (let ((display-branch
          (%client-branch-display-text branch)))
    (%client-notify conn (format nil "opening worktree ~A" display-branch))
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
                                    (format nil "worktree branch selection: ~A"
                                            display-branch)
                                    nil
                                    "worktree creation failed")
               (%client-notify conn
                               "worktree create failed")
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
                                                         (lambda ()
                                                           (%workspace-job-update
                                                            job repository :running))
                                                         :on-complete
                                                         (lambda (worktree)
                                                           (%workspace-job-update
                                                            job repository :succeeded)
                                                           (%clear-workspace-refreshing
                                                            :repository
                                                            (nerimux/workspace-model:repository-id
                                                             repository))
                                                           (when (%client-live-p conn)
                                                             (%set-client-selected-worktree
                                                              conn worktree)
                                                             (%note-worktree-layout
                                                              conn repository
                                                              (nerimux/workspace-model:worktree-path
                                                               worktree))
                                                             (when session
                                                               (%open-client-worktree-pane
                                                                session conn worktree)))
                                                           (%refresh-client-picker conn)
                                                           (%client-log-process
                                                            conn
                                                            (format nil
                                                                    "worktree branch selection: ~A -> ~A"
                                                                    display-branch
                                                                    (nerimux/workspace-model:worktree-path
                                                                     worktree))
                                                            t
                                                            "")
                                                           (%client-notify
                                                            conn
                                                            (format nil
                                                                    "worktree ready: ~A"
                                                                    (%worktree-display-path
                                                                     (nerimux/workspace-model:worktree-path
                                                                      worktree))))
                                                           (%mark-dirty))
                                                         :on-error
                                                         #'%on-error)
          (error (condition)
            (%on-error condition))))))
  t)

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
          (t
           (let ((validated-path
                   (and (stringp path)
                        (nerimux/vcs:validate-worktree-path repository path))))
             (if (and (stringp path) (null validated-path))
                 (progn
                   (%client-notify conn "path must stay under the repository")
                   t)
                 (%client-create-worktree-now
                  repository branch conn (%attach-target-session)
                  :path (if (stringp path) validated-path path)
                  :force force))))))))

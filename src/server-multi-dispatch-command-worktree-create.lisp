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

(defun %existing-path-prefix-truename (path)
  "Resolve existing symlink components and preserve a missing suffix."
  (let* ((pathname (if (pathnamep path)
                       path
                       (uiop:parse-native-namestring path)))
         (path-string (namestring pathname))
         (separator (list (code-char 47)))
         (components (remove-if
                      (lambda (component)
                        (or (string= component "")
                            (string= component ".")))
                      (uiop:split-string path-string :separator separator)))
         (resolved nil)
         (missing-p nil)
         (symlink-count 0))
    (unless (and (plusp (length path-string))
                 (char= (char path-string 0) (code-char 47)))
      (return-from %existing-path-prefix-truename nil))
    (loop while components
          for component = (pop components)
          do (cond
               ((string= component "..")
                (when missing-p
                  (return-from %existing-path-prefix-truename nil))
                (setf resolved (cdr resolved)))
               (missing-p
                (push component resolved))
               (t
                (let ((candidate
                        (format nil "/~{~A~^/~}"
                                (append (reverse resolved)
                                        (list component)))))
                  (let ((stat
                          (handler-case
                              (sb-posix:lstat candidate)
                            (sb-posix:syscall-error (condition)
                              (if (= (sb-posix:syscall-errno condition)
                                     sb-posix:enoent)
                                  :missing
                                  (return-from %existing-path-prefix-truename
                                    nil))))))
                    (cond
                      ((eq stat :missing)
                       (push component resolved)
                       (setf missing-p t))
                      ((sb-posix:s-islnk (sb-posix:stat-mode stat))
                       (let ((target
                               (handler-case
                                   (sb-posix:readlink candidate)
                                 (sb-posix:syscall-error ()
                                   (return-from %existing-path-prefix-truename
                                     nil)))))
                         (when (zerop (length target))
                           (return-from %existing-path-prefix-truename nil))
                         (incf symlink-count)
                         (when (> symlink-count 40)
                           (return-from %existing-path-prefix-truename nil))
                         (when (char= (char target 0) (code-char 47))
                           (setf resolved nil))
                         (setf components
                               (append
                                (remove-if
                                 (lambda (target-component)
                                   (or (string= target-component "")
                                       (string= target-component ".")))
                                 (uiop:split-string target
                                                    :separator separator))
                                components))))
                      (t
                       (push component resolved))))))))
    (uiop:parse-native-namestring
     (format nil "/~{~A~^/~}" (reverse resolved)))))

(defun %path-under-directory-p (path directory)
  (let ((path (string-right-trim "/" (namestring path)))
        (directory (string-right-trim "/" (namestring directory))))
    (or (string= path directory)
        (and (> (length path) (length directory))
             (char= (char path (length directory)) #\/)
             (string= directory path :end2 (length directory))))))

(defun %validated-worktree-path (repository path)
  "Return PATH's canonical absolute destination when it stays under the parent."
  (if (string= path "")
      path
      (unless (member ".."
                      (uiop:split-string path
                                         :separator (list (code-char 47)))
                      :test #'string=)
        (let* ((pathname (uiop:parse-native-namestring path))
               (pathname (if (eq :absolute (first (pathname-directory pathname)))
                             pathname
                             (merge-pathnames
                              pathname
                              (uiop:ensure-directory-pathname
                               (nerimux/workspace-model:repository-local-path
                                repository)))))
               (candidate (%existing-path-prefix-truename pathname))
               (parent-path
                 (%existing-path-prefix-truename
                  (uiop:parse-native-namestring
                   (nerimux/vcs:worktree-parent-directory repository))))
               (parent (and parent-path (ignore-errors (truename parent-path)))))
          (when (and candidate parent
                     (%path-under-directory-p candidate parent))
            (namestring candidate))))))

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
                        (%validated-worktree-path repository path))))
             (if (and (stringp path) (null validated-path))
                 (progn
                   (%client-notify conn "path must stay under the repository")
                   t)
                 (%client-create-worktree-now
                  repository branch conn (%attach-target-session)
                  :path (if (stringp path) validated-path path)
                  :force force))))))))

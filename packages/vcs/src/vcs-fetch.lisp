(in-package #:nerimux/vcs)

(defvar *fetch-lock*
  (cl-concurrent-kit:make-lock :name "nerimux-vcs-fetch"))

(defvar *in-progress-fetches*
  (make-hash-table :test #'equal))

(defun %fetch-begin (key)
  "Mark KEY in progress unless another fetch already owns it."
  (cl-concurrent-kit:with-lock-held (*fetch-lock*)
                                    (if (gethash key *in-progress-fetches*)
                                        nil
                                        (setf (gethash key
                                                       *in-progress-fetches*) t))))

(defun %fetch-end (key)
  (cl-concurrent-kit:with-lock-held (*fetch-lock*)
                                    (remhash key *in-progress-fetches*)))

(defun %fetch-optional-output (function &rest arguments)
  (handler-case
      (values (string-right-trim '(#\Newline #\Return)
                                 (or (vcs-kit:process-result-stdout
                                      (apply function arguments)) ""))
              t)
    (vcs-kit:git-exit-error (condition)
      (unless (eql 1 (vcs-kit:git-exit-error-exit-code condition))
        (error condition))
      (values nil nil))
    (vcs-kit:vcs-command-exit-error (condition)
      (unless (eql 1 (vcs-kit:vcs-command-exit-error-exit-code condition))
        (error condition))
      (values nil nil))))

(defun %probe-git-output (function &rest arguments)
  "FUNCTION's trimmed stdout, with a second value saying whether git agreed.

Unlike %FETCH-OPTIONAL-OUTPUT this swallows every failure, not just exit 1:
the questions asked through it (which branch is the default, is there an
origin) are also asked of directories that are not repositories at all."
  (handler-case
      (values (string-right-trim '(#\Newline #\Return)
                                 (or (vcs-kit:process-result-stdout
                                      (apply function arguments))
                                     ""))
              t)
    (error () (values nil nil))))

(defun %repository-origin-p (repository)
  "True when REPOSITORY has a remote named origin."
  (let ((remotes (%probe-git-output #'vcs-kit:vcs-remote
                                    (%repository-backend repository))))
    (and remotes
         (member "origin" (uiop:split-string remotes :separator '(#\Newline))
                 :test #'string=)
         t)))

(defun %repository-default-branch (repository)
  "Name REPOSITORY's default branch (R7.3).

origin/HEAD is what the remote calls its default branch, but it is only set
once `git remote set-head` has run, and a repository need not have a remote at
all. The checked-out branch answers the question next, and main or master last
-- a detached checkout of a repository whose origin/HEAD was never set leaves
nothing else to go on."
  (let ((handle (%repository-checked-handle repository)))
    (flet ((local-branch (name)
             (when (nth-value 1 (%probe-git-output
                                 #'vcs-kit:git-show-ref handle
                                 "--verify" "--quiet"
                                 (format nil "refs/heads/~A" name)))
               name))
           (origin-head-branch ()
             ;; The full ref, not --short: only the literal
             ;; refs/remotes/origin/ prefix can be stripped without guessing
             ;; where a branch name like feature/x begins.
             (let ((prefix "refs/remotes/origin/")
                   (value (%probe-git-output #'vcs-kit:git-symbolic-ref handle
                                             "-q" "refs/remotes/origin/HEAD")))
               (when (and value (eql 0 (search prefix value)))
                 (let ((branch (subseq value (length prefix))))
                   (when (plusp (length branch)) branch)))))
           (head-branch ()
             (let ((value (%probe-git-output #'vcs-kit:git-symbolic-ref handle
                                             "-q" "--short" "HEAD")))
               (when (and value (plusp (length value))) value))))
      (or (origin-head-branch)
          (head-branch)
          (local-branch "main")
          (local-branch "master")))))

(defun %fetch-default-branch (repository branch)
  "Fetch BRANCH from origin before a worktree is created from it (R7.5).

A repository with no origin has nothing to fetch and is left to its local
refs. One that has an origin is not: a fetch failure there means the branch
this is about to create from may no longer exist on the remote, so it is
signalled rather than resolved from a stale tracking ref."
  (when (and branch (plusp (length branch)) (%repository-origin-p repository))
    (vcs-kit:vcs-fetch
     (%repository-backend repository)
     "origin" (format nil "+refs/heads/~A:refs/remotes/origin/~A" branch branch)
     :execution-options
     '(:environment-update (("GIT_TERMINAL_PROMPT" . "0")
                            ("GIT_ASKPASS" . "true")
                            ("SSH_ASKPASS" . "true")
                            ("GIT_SSH_COMMAND" . "ssh -oBatchMode=yes"))))))

(defun %bare-origin-fetch-p (repository backend)
  (and (string= "true" (%rev-parse repository "--is-bare-repository"))
       (string= "origin" (%fetch-optional-output #'vcs-kit:vcs-remote backend))
       (not (nth-value 1 (%fetch-optional-output
                          #'vcs-kit:vcs-config backend
                          "--get-all" "remote.origin.fetch")))
       (not (equal "true" (%fetch-optional-output
                           #'vcs-kit:vcs-config backend
                           "--type=bool" "--get" "fetch.all")))
       (let* ((branch (%fetch-optional-output
                       #'vcs-kit:git-symbolic-ref
                       (%repository-checked-handle repository)
                       "-q" "--short" "HEAD"))
              (remote (when branch
                        (%fetch-optional-output
                         #'vcs-kit:vcs-config backend "--get"
                         (format nil "branch.~A.remote" branch)))))
         (or (null remote) (string= "origin" remote)))))

(defun %fetch-repository-remotes (repository)
  (let ((backend (%repository-backend repository)))
    (if (%bare-origin-fetch-p repository backend)
        (progn
          (vcs-kit:vcs-fetch backend "origin"
                             "+refs/heads/*:refs/remotes/origin/*")
          (let ((checked (%repository-checked-handle repository)))
            ;; A dangling symbolic HEAD can express user intent, so preserve it.
            (unless (or (nth-value 1 (%fetch-optional-output
                                      #'vcs-kit:git-symbolic-ref checked
                                      "-q" "refs/remotes/origin/HEAD"))
                        (nth-value 1 (%fetch-optional-output
                                      #'vcs-kit:git-show-ref checked
                                      "--verify" "--quiet" "refs/remotes/origin/HEAD")))
              (vcs-kit:vcs-remote backend "set-head" "origin" "-a"))))
        (vcs-kit:vcs-fetch backend))))

(defun fetch-repository (repository)
  "Fetch REPOSITORY's remotes with git fetch, then refresh its status."
  (unless repository
    (error "A repository is required to fetch."))
  (%fetch-repository-remotes repository)
  (refresh-repository-status repository)
  repository)

(defun %read-fetched-repository-status (repository)
  (%fetch-repository-remotes repository)
  (%read-repository-status repository))

(defun fetch-repository-async (repository &key
                                          on-accepted on-start on-deduplicated
                                          on-complete
                                          on-error
                                          callback-dispatch)
  "Fetch REPOSITORY once and dispatch its completion or failure callback.

A duplicate request made while the same repository is in flight completes
with NIL without starting another worker."
  (let ((key
         (list :repository (nerimux/workspace-model:repository-id repository))))
    (if (%fetch-begin key)
        (handler-case
         (progn
          (when on-accepted (funcall on-accepted))
          (first
         (refresh-repositories-async (list repository)
                                     :on-start (and on-start
                                                    (lambda (current)
                                                      (declare (ignore current))
                                                      (funcall on-start)))
                                     :status-reader
                                     #'%read-fetched-repository-status
                                     :on-complete
                                     (lambda (repositories)
                                       (declare (ignore repositories))
                                       (%fetch-end key)
                                       (when on-complete
                                         (funcall on-complete repository)))
                                     :on-error
                                     (lambda (current condition)
                                       (declare (ignore current))
                                       (when on-error
                                         (funcall on-error condition)))
                                     :callback-dispatch
                                     callback-dispatch)))
          (error (condition)
            (%fetch-end key)
            (error condition)))
        (progn
          (%dispatch-callback callback-dispatch on-deduplicated)
          (%dispatch-callback callback-dispatch on-complete nil)
          nil))))

(defun fetch-organization-async (organization &key
                                              on-accepted on-start on-deduplicated
                                              on-complete
                                              on-error
                                              callback-dispatch)
  "Fetch an organization's repositories once and dispatch one completion.

A duplicate request made while the same organization is in flight completes
with NIL without starting another set of workers."
  (let ((key
         (list :organization
               (nerimux/workspace-model:organization-id organization))))
    (if (%fetch-begin key)
        (handler-case
         (progn
         (when on-accepted (funcall on-accepted))
         (refresh-repositories-async
         (nerimux/workspace-model:organization-repositories organization)
         :on-start (and on-start
                        (lambda (repository)
                          (declare (ignore repository))
                          (funcall on-start)))
         :on-complete
         (lambda (repositories)
           (%fetch-end key)
           (when on-complete
             (funcall on-complete repositories)))
         :on-error
         (lambda (repository condition)
           (when on-error
             (funcall on-error repository condition)))
         :status-reader
         #'%read-fetched-repository-status
         :callback-dispatch
         callback-dispatch))
         (error (condition)
           (%fetch-end key)
           (error condition)))
        (progn
          (%dispatch-callback callback-dispatch on-deduplicated)
          (%dispatch-callback callback-dispatch on-complete nil)
          nil))))

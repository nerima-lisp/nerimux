(in-package #:nerimux/test/vcs)

(describe "vcs worktree commands"
  (it "emits exact synchronous worktree operation commands"
    (let* ((repository-path (%vcs-operations-existing-path))
           (secondary-path (concatenate 'string repository-path "secondary"))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path repository-path
              :branch "main"))
           (secondary-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path secondary-path
              :branch "feature/ui"))
           (commands nil)
           (execution-options
             (nerimux/vcs::%worktree-operation-execution-options)))
      (nerimux/workspace-model:repository-add-worktree repository main-worktree)
      (nerimux/workspace-model:repository-add-worktree repository secondary-worktree)
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :command-backend))
           (vcs-kit:vcs-worktree
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (push (copy-list arguments) commands)
               :command-result))
           (nerimux/vcs:list-repository-worktrees
             (lambda (current) current))
           (nerimux/vcs:refresh-repository-status
             (lambda (current) current)))
        (expect (nerimux/vcs:delete-worktree secondary-worktree))
        (expect (nerimux/vcs:delete-worktree secondary-worktree :force t))
        (expect (nerimux/vcs:lock-worktree secondary-worktree :reason "reason"))
        (expect (nerimux/vcs:lock-worktree secondary-worktree :reason ""))
        (expect (nerimux/vcs:unlock-worktree secondary-worktree))
        (expect (eq :command-result
                    (nerimux/vcs:prune-worktrees
                     repository
                     :dry-run nil
                     :verbose t)))
        (expect
         (equal
          (list (list "remove" secondary-path
                      :execution-options execution-options)
                (list "remove" "--force" secondary-path
                      :execution-options execution-options)
                (list "lock" "--reason" "reason" secondary-path
                      :execution-options execution-options)
                (list "lock" secondary-path
                      :execution-options execution-options)
                (list "unlock" secondary-path
                      :execution-options execution-options)
                (list "prune" "--verbose"
                      :execution-options execution-options))
          (nreverse commands)))
        (let ((condition-seen nil))
          (handler-case
              (nerimux/vcs:delete-worktree main-worktree)
            (error (condition)
              (setf condition-seen condition)))
          (expect (typep condition-seen 'error))))))

  (it "bounds fake git worktree writes and disables terminal prompts"
    (let* ((directory (namestring (host-kit:temporary-directory)))
           (script (merge-pathnames "nerimux-fake-git-timeout.sh"
                                    (host-kit:temporary-directory)))
           (environment-file (merge-pathnames "nerimux-fake-git-environment"
                                              (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path directory))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path (concatenate 'string directory "secondary")
              :branch "feature/ui"))
           (backend nil)
           (condition-seen nil))
      (with-open-file (stream script :direction :output :if-exists :supersede)
        (format stream "#!/bin/sh~%printf '%s' \"${GIT_TERMINAL_PROMPT-unset}\" > '~A'~%sleep 5~%"
                (namestring environment-file)))
      (uiop:run-program (list "chmod" "+x" (namestring script)))
      (setf backend
            (vcs-kit:make-vcs-repository
             directory
             :executable (namestring script)
             :default-timeout 30d0))
      (let ((nerimux/vcs::*worktree-operation-timeout-seconds* 0.1d0))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-backend
               (lambda (current)
                 (declare (ignore current))
                 backend)))
          (handler-case
              (nerimux/vcs::%delete-worktree-command worktree nil)
            (error (condition)
              (setf condition-seen condition)))))
      (expect (typep condition-seen 'vcs-kit:vcs-command-timeout-error))
      (with-open-file (stream environment-file :direction :input)
        (expect (string= "0" (read-line stream))))))

  (it "rejects invalid worktree and repository inputs before invoking VCS"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path repository-path
              :branch "main"))
           (same-path-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path (copy-seq repository-path)
              :branch "main"))
           (calls 0))
      (nerimux/workspace-model:repository-add-worktree repository main-worktree)
      (with-stubbed-fdefinition
          ((vcs-kit:vcs-worktree
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf calls))))
        (dolist (thunk
                 (list
                  (lambda () (nerimux/vcs:delete-worktree nil))
                  (lambda () (nerimux/vcs:lock-worktree nil))
                  (lambda () (nerimux/vcs:unlock-worktree nil))
                  (lambda () (nerimux/vcs:prune-worktrees nil))
                  (lambda () (nerimux/vcs:delete-worktree same-path-worktree))))
          (let ((condition-seen nil))
            (handler-case (funcall thunk)
              (error (condition) (setf condition-seen condition)))
            (expect (typep condition-seen 'error))))
        (expect (zerop calls)))))
  (it "creates from local and remote branches, reuses checked-out branches, and creates unmatched branches"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (execution-options
             (nerimux/vcs::%worktree-operation-execution-options)))
      (labels ((run-case (branch candidates expected-path expected-branch-arguments
                                 expected-worktree-arguments)
                 (let ((branch-commands nil)
                       (worktree-commands nil))
                   (with-stubbed-fdefinition
                       ((nerimux/vcs::%read-worktree-branch-candidates
                          (lambda (current)
                            (unless (eq current repository)
                              (error "Unexpected repository"))
                            candidates))
                        (nerimux/vcs::%repository-backend
                          (lambda (current)
                            (unless (eq current repository)
                              (error "Unexpected repository"))
                            :backend))
                        (nerimux/vcs::%short-sha
                          (lambda (current reference)
                            (declare (ignore current reference))
                            "short"))
                        (nerimux/vcs::%resolve-worktree-path
                          (lambda (current short path)
                            (declare (ignore current))
                            (unless (and (string= short "short") (null path))
                              (error "Unexpected path resolution"))
                            "/tmp/generated-worktree"))
                        (nerimux/vcs::%default-branch-start-point
                          (lambda (current)
                            (declare (ignore current))
                            "refs/heads/main"))
                        (vcs-kit:vcs-branch
                          (lambda (backend &rest arguments)
                            (unless (eq backend :backend)
                              (error "Unexpected VCS backend"))
                            (push arguments branch-commands)))
                        (vcs-kit:vcs-worktree
                          (lambda (backend &rest arguments)
                            (unless (eq backend :backend)
                              (error "Unexpected VCS backend"))
                            (push arguments worktree-commands))))
                     (expect
                      (string= expected-path
                               (nerimux/vcs::%create-worktree-command
                                repository branch nil nil nil)))
                     (expect (equal expected-branch-arguments
                                    (first branch-commands)))
                     (expect (equal expected-worktree-arguments
                                    (first worktree-commands)))
                     (expect (= (if expected-branch-arguments 1 0)
                                (length branch-commands)))
                     (expect (= (if expected-worktree-arguments 1 0)
                                (length worktree-commands)))))))
        (run-case
         "feature/local"
         (list (list :branch "feature/local"
                     :kind :local
                     :ref "refs/heads/feature/local"
                     :remote nil
                     :worktree nil))
         "/tmp/generated-worktree"
         nil
         (list "add" "--" "/tmp/generated-worktree" "feature/local"
               :execution-options execution-options))
        (run-case
         "feature/remote"
         (list (list :branch "feature/remote"
                     :kind :remote
                     :remote "origin"
                     :ref "refs/remotes/origin/feature/remote"
                     :worktree nil))
         "/tmp/generated-worktree"
         (list "--track" "--" "feature/remote" "origin/feature/remote" :execution-options execution-options)
         (list "add" "--" "/tmp/generated-worktree" "feature/remote"
               :execution-options execution-options))
        (let ((worktree
                (nerimux/workspace-model:make-worktree
                 :repository repository
                 :path "/tmp/checked-out-feature"
                 :branch "feature/checked")))
          (run-case
           "feature/checked"
           (list (list :branch "feature/checked"
                       :kind :local
                       :ref "refs/heads/feature/checked"
                       :remote nil
                       :worktree worktree))
           "/tmp/checked-out-feature"
           nil
           nil))
        (run-case
         "feature/new"
         nil
         "/tmp/generated-worktree"
         (list "--" "feature/new" "refs/heads/main"
               :execution-options execution-options)
         (list "add" "--" "/tmp/generated-worktree" "feature/new"
               :execution-options execution-options)))))
  (it "lists local and remote branch candidates with checked-out worktrees asynchronously"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path "/tmp/worktree-main"
              :branch "main"))
           (ref-output
             (format nil
                     "refs/heads/main~C~Crefs/remotes/origin/main~%refs/remotes/origin/main~C~C~%refs/remotes/origin/topic/remote-only~C~C~%refs/remotes/origin/HEAD~Crefs/remotes/origin/main~C~%"
                     #\Null #\Null #\Null #\Null #\Null #\Null #\Null #\Null))
           (candidates nil)
           (condition-seen nil)
           (thread nil))
      (nerimux/workspace-model:repository-add-worktree repository main-worktree)
      (with-stubbed-fdefinition
          ((nerimux/vcs:list-repository-worktrees
             (lambda (current) current))
           (nerimux/vcs::%run-git-read
             (lambda (directory subcommand &rest arguments)
               (declare (ignore directory arguments))
               (cond
                 ((string= subcommand "remote") (format nil "origin~%backup~%"))
                 ((string= subcommand "for-each-ref") ref-output)
                 (t (error "Unexpected git read: ~A" subcommand))))))
        (setf thread
              (nerimux/vcs:list-worktree-branch-candidates-async
               repository
               :on-complete (lambda (result) (setf candidates result))
               :on-error (lambda (condition) (setf condition-seen condition))))
        (expect thread)
        (cl-concurrent-kit:join-thread thread :timeout 2)
        (expect (null condition-seen))
        (let* ((local-main
                 (find-if (lambda (candidate)
                            (and (eq :local (getf candidate :kind))
                                 (string= "main" (getf candidate :branch))))
                          candidates))
               (remote-main
                 (find-if (lambda (candidate)
                            (and (eq :remote (getf candidate :kind))
                                 (string= "main" (getf candidate :branch))))
                          candidates))
               (remote-only
                 (find-if (lambda (candidate)
                            (and (eq :remote (getf candidate :kind))
                                 (string= "topic/remote-only" (getf candidate :branch))))
                          candidates)))
          (expect (= 3 (length candidates)))
          (expect (eq main-worktree (getf local-main :worktree)))
          (expect (string= "origin" (getf remote-main :remote)))
          (expect (eq main-worktree (getf remote-main :worktree)))
          (expect (string= "refs/remotes/origin/topic/remote-only"
                           (getf remote-only :ref)))
          (expect (null (getf remote-only :worktree)))))))
  (it "rejects option-like branch names before reading refs or invoking git"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (candidate-reads 0)
           (git-writes 0)
           (condition-seen nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-worktree-branch-candidates
             (lambda (current)
               (declare (ignore current))
               (incf candidate-reads)
               nil))
           (vcs-kit:vcs-worktree
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf git-writes))))
        (handler-case
            (nerimux/vcs::%create-worktree-command
             repository "--force" nil nil nil)
          (simple-error (condition)
            (setf condition-seen condition))))
      (expect (typep condition-seen 'simple-error))
      (expect (zerop candidate-reads))
      (expect (zerop git-writes)))))
(describe "vcs live-pane-delete attachment safety"
  (it "live-pane-delete rejects live panes before synchronous and asynchronous command dispatch even with force"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path repository-path :branch "main"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path (concatenate 'string repository-path "attached")
              :branch "feature/attached"))
           (pane (make-pane :id 42 :fd 1))
           (commands nil)
           (refreshes 0))
      (nerimux/workspace-model:repository-add-worktree repository main-worktree)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/pane:worktree-add-pane worktree pane)
      (expect (nerimux/pane:pane-live-p pane))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :command-backend))
           (vcs-kit:vcs-worktree
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (push arguments commands)))
           (nerimux/vcs:list-repository-worktrees
             (lambda (current) (incf refreshes) current))
           (nerimux/vcs:refresh-repository-status
             (lambda (current) (incf refreshes) current)))
        (dolist (delete-command
                 (list (lambda (target force)
                         (nerimux/vcs:delete-worktree target :force force))
                       #'nerimux/vcs::%delete-worktree-command))
          (dolist (force '(nil t))
            (let ((condition-seen nil))
              (handler-case (funcall delete-command worktree force)
                (error (condition) (setf condition-seen condition)))
              (expect (typep condition-seen 'error))
              (expect (null commands))
              (expect (zerop refreshes))
              (expect (eq worktree (nerimux/pane:pane-worktree pane)))
              (expect (nerimux/pane:pane-live-p pane))))))))

  (it "live-pane-delete allows dead panes through synchronous and asynchronous command dispatch"
    (let* ((repository-path (%vcs-operations-existing-path))
           (secondary-path (concatenate 'string repository-path "dead-pane"))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path repository-path :branch "main"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path secondary-path :branch "feature/dead"))
           (pane (make-pane :id 43 :fd 0))
           (commands nil)
           (execution-options
             (nerimux/vcs::%worktree-operation-execution-options)))
      (nerimux/workspace-model:repository-add-worktree repository main-worktree)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/pane:worktree-add-pane worktree pane)
      (expect (not (nerimux/pane:pane-live-p pane)))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :command-backend))
           (vcs-kit:vcs-worktree
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (push arguments commands)))
           (nerimux/vcs:list-repository-worktrees
             (lambda (current) current))
           (nerimux/vcs:refresh-repository-status
             (lambda (current) current)))
        (dolist (delete-command
                 (list (lambda (target force)
                         (nerimux/vcs:delete-worktree target :force force))
                       #'nerimux/vcs::%delete-worktree-command))
          (dolist (force '(nil t))
            (expect (funcall delete-command worktree force))))
        (expect
         (equal (list (list "remove" secondary-path
                             :execution-options execution-options)
                      (list "remove" "--force" secondary-path
                            :execution-options execution-options)
                      (list "remove" secondary-path
                            :execution-options execution-options)
                      (list "remove" "--force" secondary-path
                            :execution-options execution-options))
                (nreverse commands)))))))
(describe "vcs live-pane-delete independent agent history"
  (it "live-pane-delete protects an agent pane outside panes until its fd closes"
    (let* ((repository-path (%vcs-operations-existing-path))
           (secondary-path (concatenate 'string repository-path "agent-history"))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path repository-path :branch "main"))
           (agent-pane (make-pane :id 44 :fd 0 :agent-kind :codex
                                  :process-exited-p t))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path secondary-path :branch "feature/history"
              :agent-pane agent-pane))
           (commands nil)
           (refreshes 0)
           (execution-options
             (nerimux/vcs::%worktree-operation-execution-options)))
      (nerimux/workspace-model:repository-add-worktree repository main-worktree)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (expect (null (nerimux/workspace-model:worktree-panes worktree)))
      (expect (eq agent-pane (nerimux/workspace-model:worktree-agent-pane worktree)))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :command-backend))
           (vcs-kit:vcs-worktree
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (push arguments commands)))
           (nerimux/vcs:list-repository-worktrees
             (lambda (current) (incf refreshes) current))
           (nerimux/vcs:refresh-repository-status
             (lambda (current) (incf refreshes) current)))
        (dolist (fd '(0 1))
          (setf (nerimux/pane:pane-fd agent-pane) fd)
          (expect (eql (not (null (nerimux/pane:pane-live-p agent-pane)))
                       (plusp fd)))
          (dolist (delete-command
                   (list (lambda (target force)
                           (nerimux/vcs:delete-worktree target :force force))
                         #'nerimux/vcs::%delete-worktree-command))
            (dolist (force '(nil t))
              (setf commands nil refreshes 0)
              (if (plusp fd)
                  (let ((condition-seen nil))
                    (handler-case (funcall delete-command worktree force)
                      (error (condition) (setf condition-seen condition)))
                    (expect (typep condition-seen 'error))
                    (expect (null commands))
                    (expect (zerop refreshes)))
                  (progn
                    (expect (funcall delete-command worktree force))
                    (expect (equal (list (if force
                                            (list "remove" "--force" secondary-path
                                                  :execution-options execution-options)
                                            (list "remove" secondary-path
                                                  :execution-options execution-options)))
                                   commands))))
              (expect (null (nerimux/workspace-model:worktree-panes worktree)))
              (expect (eq agent-pane
                          (nerimux/workspace-model:worktree-agent-pane worktree)))
              (expect (= fd (nerimux/pane:pane-fd agent-pane))))))))))

(describe "vcs worktree branch selection safety"
  (it "rejects previous-checkout branch syntax before reading refs or invoking git"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path (%vcs-operations-existing-path)))
           (candidate-reads 0)
           (git-writes 0)
           (condition-seen nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-worktree-branch-candidates
             (lambda (current)
               (declare (ignore current))
               (incf candidate-reads)
               nil))
           (vcs-kit:vcs-branch
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf git-writes)))
           (vcs-kit:vcs-worktree
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf git-writes))))
        (handler-case
            (nerimux/vcs::%create-worktree-command
             repository "@{-1}" nil nil nil)
          (error (condition)
            (setf condition-seen condition))))
      (expect (typep condition-seen 'error))
      (expect (zerop candidate-reads))
      (expect (zerop git-writes))))
  (it "rejects a selector with two remote interpretations before invoking git"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path (%vcs-operations-existing-path)))
           (candidate-reads 0)
           (git-writes 0)
           (condition-seen nil)
           (candidates
             (list (list :branch "topic"
                         :kind :remote
                         :remote "origin"
                         :ref "refs/remotes/origin/topic"
                         :worktree nil)
                   (list :branch "origin/topic"
                         :kind :remote
                         :remote "origin"
                         :ref "refs/remotes/origin/origin/topic"
                         :worktree nil))))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-worktree-branch-candidates
             (lambda (current)
               (unless (eq current repository)
                 (error "Unexpected repository"))
               (incf candidate-reads)
               candidates))
           (vcs-kit:vcs-branch
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf git-writes)))
           (vcs-kit:vcs-worktree
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf git-writes))))
        (handler-case
            (nerimux/vcs::%create-worktree-command
             repository "origin/topic" nil nil nil)
          (error (condition)
            (setf condition-seen condition))))
      (expect (typep condition-seen 'error))
      (expect (= 1 candidate-reads))
      (expect (zerop git-writes))))
  (it "removes the new branch when worktree attachment fails"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path (%vcs-operations-existing-path)))
           (branch-commands nil)
           (worktree-command nil)
           (condition-seen nil)
           (execution-options
             (nerimux/vcs::%worktree-operation-execution-options)))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%repository-backend
             (lambda (current)
               (unless (eq current repository)
                 (error "Unexpected repository"))
               :backend))
           (vcs-kit:vcs-branch
             (lambda (backend &rest arguments)
               (unless (eq backend :backend)
                 (error "Unexpected VCS backend"))
               (push arguments branch-commands)))
           (vcs-kit:vcs-worktree
             (lambda (backend &rest arguments)
               (unless (eq backend :backend)
                 (error "Unexpected VCS backend"))
               (setf worktree-command arguments)
               (error "worktree path occupied"))))
        (handler-case
            (nerimux/vcs::%create-worktree-from-new-branch
             repository "feature/cleanup" "/tmp/occupied"
             "refs/heads/main" nil)
          (error (condition)
            (setf condition-seen condition))))
      (expect (typep condition-seen 'error))
      (expect
       (equal
        (list (list "--" "feature/cleanup" "refs/heads/main"
                    :execution-options execution-options)
              (list "-D" "--" "feature/cleanup"
                    :execution-options execution-options))
        (reverse branch-commands)))
      (expect
       (equal (list "add" "--" "/tmp/occupied" "feature/cleanup"
                    :execution-options execution-options)
              worktree-command))))
  (it "requires an on-error callback when listing candidates"
    (let ((condition-seen nil))
      (handler-case
          (nerimux/vcs:list-worktree-branch-candidates-async nil)
        (error (condition)
          (setf condition-seen condition)))
      (expect (typep condition-seen 'error)))))

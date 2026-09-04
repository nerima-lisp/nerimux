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
           (commands nil))
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
          (list (list "remove" secondary-path)
                (list "remove" "--force" secondary-path)
                (list "lock" "--reason" "reason" secondary-path)
                (list "lock" secondary-path)
                (list "unlock" secondary-path)
                (list "prune" "--verbose"))
          (nreverse commands)))
        (let ((condition-seen nil))
          (handler-case
              (nerimux/vcs:delete-worktree main-worktree)
            (error (condition)
              (setf condition-seen condition)))
          (expect (typep condition-seen 'error))))))

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
        (expect (zerop calls))))))

(in-package #:nerimux/test)

(defun %make-worktree-operation-fixture ()
  (let* ((organization
           (nerimux/workspace-model:make-organization
            :id "org-errors"
            :host "github.com"
            :name "team-errors"))
         (repository
           (nerimux/workspace-model:make-repository
            :id "repo-errors"
            :organization organization
            :specification "github.com/team-errors/repo-errors"))
         (worktree
           (nerimux/workspace-model:make-worktree
            :id "worktree-errors"
            :repository repository
            :path "/tmp/worktree-errors"
            :branch "feature/errors"
            :head "feature/errors"))
         (conn (%make-test-conn)))
    (nerimux/workspace-model:organization-add-repository organization repository)
    (nerimux/workspace-model:repository-add-worktree repository worktree)
    (values repository worktree conn)))

(defun %worktree-message-seen-p (conn message)
  (find message
        (nerimux::client-conn-message-log conn)
        :test #'string=))

(describe "server-multi-error-suite"

  (it "worktree-operations-report-async-and-synchronous-failures"
    (with-fake-session (s)
      (multiple-value-bind (repository worktree conn)
          (%make-worktree-operation-fixture)
        (let* ((nerimux::*clients* (list conn))
               (available
                 (fdefinition 'nerimux/vcs:vcs-package-available-p))
               (create-fn (fdefinition 'nerimux/vcs:create-worktree-async))
               (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
               (lock-fn (fdefinition 'nerimux/vcs:lock-worktree-async))
               (unlock-fn (fdefinition 'nerimux/vcs:unlock-worktree-async))
               (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async)))
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                       (lambda () t))

                 (nerimux::%set-client-selected-tree-object conn repository)
                 (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                       (lambda (received-repository
                                &key branch path force on-complete on-error
                                  callback-dispatch)
                         (declare
                          (ignore received-repository branch path force on-complete
                                 callback-dispatch))
                         (funcall on-error "create async failure")
                         t))
                 (nerimux::%client-create-worktree
                  conn nil '("--confirm" "--branch" "feature/create"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree create failed: create async failure"))
                 (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         (error "create synchronous failure")))
                 (nerimux::%client-create-worktree
                  conn nil '("--confirm" "--branch" "feature/create"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree create failed: create synchronous failure"))

                 (nerimux::%set-client-selected-tree-object conn worktree)
                 (setf (fdefinition 'nerimux/vcs:delete-worktree-async)
                       (lambda (received-worktree
                                &key force on-complete on-error callback-dispatch)
                         (declare (ignore received-worktree force on-complete
                                             callback-dispatch))
                         (funcall on-error "delete async failure")
                         t))
                 (nerimux::%client-delete-worktree conn nil '("--confirm"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree delete failed: delete async failure"))
                 (setf (fdefinition 'nerimux/vcs:delete-worktree-async)
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         (error "delete synchronous failure")))
                 (nerimux::%client-delete-worktree conn nil '("--confirm"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree delete failed: delete synchronous failure"))

                 (setf (fdefinition 'nerimux/vcs:lock-worktree-async)
                       (lambda (received-worktree
                                &key reason on-complete on-error callback-dispatch)
                         (declare (ignore received-worktree reason on-complete
                                             callback-dispatch))
                         (funcall on-error "lock async failure")
                         t))
                 (nerimux::%client-lock-worktree conn nil '("--confirm"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree lock failed: lock async failure"))
                 (setf (fdefinition 'nerimux/vcs:lock-worktree-async)
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         (error "lock synchronous failure")))
                 (nerimux::%client-lock-worktree conn nil '("--confirm"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree lock failed: lock synchronous failure"))

                 (setf (fdefinition 'nerimux/vcs:unlock-worktree-async)
                       (lambda (received-worktree
                                &key on-complete on-error callback-dispatch)
                         (declare (ignore received-worktree on-complete
                                             callback-dispatch))
                         (funcall on-error "unlock async failure")
                         t))
                 (nerimux::%client-unlock-worktree conn nil '("--confirm"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree unlock failed: unlock async failure"))
                 (setf (fdefinition 'nerimux/vcs:unlock-worktree-async)
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         (error "unlock synchronous failure")))
                 (nerimux::%client-unlock-worktree conn nil '("--confirm"))
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree unlock failed: unlock synchronous failure"))

                 (nerimux::%set-client-selected-tree-object conn repository)
                 (setf (fdefinition 'nerimux/vcs:prune-worktrees-async)
                       (lambda (received-repository
                                &key dry-run verbose on-complete on-error
                                  callback-dispatch)
                         (declare
                          (ignore received-repository dry-run verbose on-complete
                                 callback-dispatch))
                         (funcall on-error "prune async failure")
                         t))
                 (nerimux::%client-prune-worktrees conn nil nil :dry-run t)
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree prune failed: prune async failure"))
                 (setf (fdefinition 'nerimux/vcs:prune-worktrees-async)
                       (lambda (&rest arguments)
                         (declare (ignore arguments))
                         (error "prune synchronous failure")))
                 (nerimux::%client-prune-worktrees conn nil nil :dry-run t)
                 (expect
                  (%worktree-message-seen-p
                   conn
                   "worktree prune failed: prune synchronous failure")))
            (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                  (fdefinition 'nerimux/vcs:create-worktree-async) create-fn
                  (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn
                  (fdefinition 'nerimux/vcs:lock-worktree-async) lock-fn
                  (fdefinition 'nerimux/vcs:unlock-worktree-async) unlock-fn
                  (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn))))))

  (it "worktree-create-and-delete-completions-update-selection"
    (with-fake-session (s)
      (multiple-value-bind (repository worktree conn)
          (%make-worktree-operation-fixture)
        (let* ((nerimux::*clients* (list conn))
               (available
                 (fdefinition 'nerimux/vcs:vcs-package-available-p))
               (create-fn (fdefinition 'nerimux/vcs:create-worktree-async))
               (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
               )
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                       (lambda () t)
                     (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository
                              &key branch path force on-complete on-error
                                callback-dispatch)
                       (declare
                        (ignore received-repository branch path force on-error
                               callback-dispatch))
                       (funcall on-complete worktree)
                       t))
                 (nerimux::%set-client-selected-tree-object conn repository)
                 (nerimux::%client-create-worktree
                  conn nil '("--confirm" "--branch" "feature/completed"))
                 (expect (eq worktree
                             (nerimux::client-conn-selected-worktree conn)))
                 (expect
                  (%worktree-message-seen-p conn "worktree created"))

                 (setf (fdefinition 'nerimux/vcs:delete-worktree-async)
                       (lambda (received-worktree
                                &key force on-complete on-error callback-dispatch)
                         (declare (ignore received-worktree force on-error
                                             callback-dispatch))
                         (funcall on-complete nil)
                         t))
                 (nerimux::%set-client-selected-tree-object conn worktree)
                 (nerimux::%client-delete-worktree conn nil '("--confirm"))
                 (expect (null (nerimux::client-conn-selected-worktree conn)))
                 (expect
                  (%worktree-message-seen-p conn "worktree deleted")))
            (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                  (fdefinition 'nerimux/vcs:create-worktree-async) create-fn
                 (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))) (it "worktree-operations-reject-unconfirmed-and-unavailable-requests"
    (with-fake-session (s)
      (multiple-value-bind (repository worktree conn)
          (%make-worktree-operation-fixture)
        (let* ((nerimux::*clients* (list conn))
               (available
                 (fdefinition 'nerimux/vcs:vcs-package-available-p)))
          (unwind-protect
               (progn
                 (nerimux::%client-create-worktree conn nil nil)
                 (nerimux::%client-lock-worktree conn nil nil)
                 (nerimux::%client-unlock-worktree conn nil nil)
                 (expect (%worktree-message-seen-p
                          conn "worktree create requires --confirm"))
                 (expect (%worktree-message-seen-p
                          conn "worktree lock requires --confirm"))
                 (expect (%worktree-message-seen-p
                          conn "worktree unlock requires --confirm"))
                 (nerimux::%set-client-selected-tree-object conn nil)
                 (nerimux::%client-create-worktree conn nil
                                                   '("--confirm" "--branch" "feature/missing"))
                 (expect (%worktree-message-seen-p
                          conn "worktree create requires a repository"))
                 (nerimux::%client-lock-worktree conn nil '("--confirm"))
                 (nerimux::%client-unlock-worktree conn nil '("--confirm"))
                 (expect (%worktree-message-seen-p
                          conn "worktree lock requires a worktree"))
                 (expect (%worktree-message-seen-p
                          conn "worktree unlock requires a worktree"))
                 (nerimux::%set-client-selected-tree-object conn repository)
                 (nerimux::%client-create-worktree conn nil '("--confirm"))
                 (expect (%worktree-message-seen-p
                          conn "worktree create requires a branch"))
                 (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                       (lambda () nil))
                 (nerimux::%client-create-worktree
                  conn nil '("--confirm" "--branch" "feature/unavailable"))
                 (nerimux::%set-client-selected-tree-object conn worktree)
                 (nerimux::%client-lock-worktree conn nil '("--confirm"))
                 (nerimux::%client-unlock-worktree conn nil '("--confirm"))
                 (nerimux::%client-delete-worktree conn nil '("--confirm"))
                 (nerimux::%set-client-selected-tree-object conn nil)
                 (nerimux::%client-prune-worktrees conn nil nil :dry-run t)
                 (expect (%worktree-message-seen-p
                          conn "VCS adapter unavailable")))
            (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                  available)))))))

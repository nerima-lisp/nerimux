(in-package #:nerimux/vcs)

(defmacro define-worktree-async-operation (name lambda-list
                                                documentation
                                                thread-name
                                                command-form)
  `(defun ,name ,lambda-list
     ,documentation
     (%run-vcs-operation-async ,thread-name
                               (lambda ()
                                 (let ((repository ,command-form))
                                   (%capture-worktree-operation-result
                                    repository
                                    t)))
                               #'%apply-worktree-operation-result
                               on-complete
                               on-error
                               callback-dispatch)))

(defun create-worktree-async (repository &key
                                         branch
                                         path
                                         start-point
                                         force
                                         on-complete
                                         on-error
                                         callback-dispatch)
  "Create a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async "nerimux-vcs-worktree-create"
                            (lambda ()
                              (%capture-worktree-operation-result repository
                                                                  (%create-worktree-command
                                                                   repository
                                                                   branch
                                                                   path
                                                                   start-point
                                                                   force)))
                            (lambda (operation-result)
                              (%apply-created-worktree repository
                                                       operation-result))
                            on-complete
                            on-error
                            callback-dispatch))

(define-worktree-async-operation delete-worktree-async
                                 (worktree &key
                                           force
                                           on-complete
                                           on-error
                                           callback-dispatch)
                                 "Delete a worktree on a worker thread and invoke one callback."
                                 "nerimux-vcs-worktree-delete"
                                 (%delete-worktree-command worktree force))

(define-worktree-async-operation lock-worktree-async
                                 (worktree &key
                                           reason
                                           on-complete
                                           on-error
                                           callback-dispatch)
                                 "Lock a worktree on a worker thread and invoke one callback."
                                 "nerimux-vcs-worktree-lock"
                                 (%lock-worktree-command worktree reason))

(define-worktree-async-operation unlock-worktree-async
                                 (worktree &key
                                           on-complete
                                           on-error
                                           callback-dispatch)
                                 "Unlock a worktree on a worker thread and invoke one callback."
                                 "nerimux-vcs-worktree-unlock"
                                 (%unlock-worktree-command worktree))

(defun prune-worktrees-async (repository &key
                                         (dry-run t)
                                         verbose
                                         on-complete
                                         on-error
                                         callback-dispatch)
  "Prune a repository's worktrees on a worker thread and invoke one callback.

DRY-RUN defaults true, matching PRUNE-WORKTREES, so an omitted keyword here
stays non-destructive instead of silently forwarding a false DRY-RUN."
  (%run-vcs-operation-async "nerimux-vcs-worktree-prune"
                            (lambda ()
                              (let ((worker-result
                                     (%prune-worktrees-command repository
                                                               dry-run
                                                               verbose)))
                                (%capture-worktree-operation-result
                                 (first worker-result)
                                 (second worker-result))))
                            (lambda (operation-result)
                              (%apply-worktree-operation-result
                               operation-result))
                            on-complete
                            on-error
                            callback-dispatch))

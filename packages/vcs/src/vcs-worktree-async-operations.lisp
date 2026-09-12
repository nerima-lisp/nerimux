(in-package #:nerimux/vcs)

(defmacro define-worktree-async-operation (name lambda-list
                                                documentation
                                                thread-name
                                                command-form)
  `(defun ,name ,lambda-list
     ,documentation
     (let ((generation (%begin-worktree-request worktree)))
       (%run-vcs-operation-async ,thread-name
                               (lambda ()
                                 (let ((repository ,command-form))
                                   (%capture-worktree-operation-result
                                    repository
                                    t generation)))
                               #'%apply-worktree-operation-result
                               on-complete
                               on-error
                               callback-dispatch))))

(defstruct (detached-worktree-result (:constructor %make-detached-worktree-result))
  (path nil :read-only t)
  (head nil :read-only t)
  worktree
  fetch-error
  refresh-error)

(defun %create-detached-worktree-result (repository)
  "Create a detached worktree at REPOSITORY's default-branch tip (R7.5).

The fetch that precedes it is advisory: %REPOSITORY-DEFAULT-BRANCH answers
with the checked-out branch when origin/HEAD was never set, and that branch
need not exist on the remote at all, so a fetch failure there says nothing
about whether the start point resolves. What a failed fetch does rule out is
the remote-tracking ref, which no longer stands for anything the remote has
confirmed, so the start point is then taken from the local branch or HEAD.
The failure travels back on the receipt for the dispatch layer to log."
  (let ((fetch-error
          (handler-case
              (progn (%fetch-default-branch repository
                                            (%repository-default-branch repository))
                     nil)
            (error (condition) condition))))
    (let* ((head (%default-branch-start-point repository
                                              :remote-ref-p (null fetch-error)))
           (short-head (%rev-parse repository "--short" head))
           (path (%resolve-worktree-path repository short-head nil)))
      (vcs-kit:vcs-worktree (%repository-backend repository)
                            "add" "--detach" path head)
      (let ((receipt (%make-detached-worktree-result :path path :head head
                                                     :fetch-error fetch-error)))
        (cons receipt
              (handler-case (%read-repository-refresh repository)
                (error (condition)
                  (setf (detached-worktree-result-refresh-error receipt) condition)
                  nil)))))))

(defun %apply-detached-worktree-result (repository result)
  (let ((receipt (car result)))
    (unless (detached-worktree-result-refresh-error receipt)
      (handler-case
          (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
            (%apply-repository-refresh repository (cdr result))
            (setf (detached-worktree-result-worktree receipt)
                  (%created-worktree-by-path
                   repository (detached-worktree-result-path receipt))))
        (error (condition)
          (setf (detached-worktree-result-refresh-error receipt) condition))))
    receipt))

(defun create-detached-worktree-async (repository &key on-complete on-error on-start
                                                    callback-dispatch)
  "Create a detached worktree at the default branch's tip, fetching first when
the remote has that branch. ON-COMPLETE receives a DETACHED-WORKTREE-RESULT
even if the fetch or the catalog refresh fails.
Reject concurrent detached creation for the same canonical repository path.
The reservation lasts until callback delivery; generic fetch is independent.
Joining the returned thread also yields the creation receipt and a worker or
dispatch error as two values, so failed delivery cannot hide a created path."
  (let ((key (list :detached-worktree
                   (namestring
                    (truename (nerimux/workspace-model:repository-local-path
                               repository)))))
        (generation nil)
        (released-p nil)
        (release-requested-p nil)
        (active-deliveries 0)
        (delivery-lock (cl-concurrent-kit:make-lock :name "detached-worktree-delivery")))
    (unless (%fetch-begin key)
      (%dispatch-callback callback-dispatch on-error
                          (make-condition 'simple-error
                                          :format-control "Detached worktree creation already in progress"))
      (return-from create-detached-worktree-async nil))
    (setf generation (%begin-repository-data-generation repository))
    (labels ((release-if-idle ()
               (when (and release-requested-p (zerop active-deliveries)
                          (not released-p))
                 (setf released-p t)
                 (%fetch-end key)))
             (release-reservation ()
               (cl-concurrent-kit:with-lock-held (delivery-lock)
                 (setf release-requested-p t)
                 (release-if-idle)))
             (dispatch (callback &rest arguments)
               (let ((state :pending))
                 (handler-case
                     (%dispatch-callback
                      callback-dispatch
                      (lambda ()
                        (when (cl-concurrent-kit:with-lock-held (delivery-lock)
                                (when (eq state :pending)
                                  (setf state :delivered)
                                  (incf active-deliveries)))
                          (unwind-protect
                               (apply callback arguments)
                            (cl-concurrent-kit:with-lock-held (delivery-lock)
                              (decf active-deliveries)
                              (release-if-idle))))))
                   (error (condition)
                     (cl-concurrent-kit:with-lock-held (delivery-lock)
                       (when (eq state :pending)
                         (setf state :cancelled)))
                     (error condition)))))
             (complete (receipt)
               (unwind-protect
                    (when on-complete (funcall on-complete receipt))
                 (release-reservation)))
             (fail (condition)
               (unwind-protect
                    (when on-error (funcall on-error condition))
                 (release-reservation))))
      (handler-case
          (cl-concurrent-kit:make-thread
           (lambda ()
             (let ((receipt nil))
               (handler-case
                   (let ((result (progn
                                   (when on-start (dispatch on-start))
                                   (%create-detached-worktree-result repository))))
                     (setf receipt (car result))
                     (dispatch
                      (lambda ()
                        (handler-case
                            (complete
                             (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
                               (if (%repository-data-generation-current-p
                                    repository generation :before-apply t)
                                   (%apply-detached-worktree-result repository result)
                                   (progn
                                     (unless (detached-worktree-result-refresh-error receipt)
                                       (setf (detached-worktree-result-refresh-error receipt)
                                             (make-condition 'simple-error
                                                             :format-control "Worktree refresh was superseded; refresh the workspace catalogue.")))
                                     receipt))))
                          (error (condition) (fail condition)))))
                     (values receipt nil))
                 (error (condition)
                   (handler-case
                       (dispatch #'fail condition)
                     (error () (release-reservation)))
                   (values receipt condition)))))
           :name "nerimux-vcs-detached-create")
        (error (condition)
          (release-reservation)
          (error condition))))))
(defun create-worktree-async (repository &key
                                         branch
                                         path
                                         start-point
                                         force
                                         on-start
                                         on-complete
                                         on-error
                                         callback-dispatch)
  "Create a worktree on a worker thread and invoke one callback."
  (let ((generation (%begin-worktree-request repository)))
    (%run-vcs-operation-async "nerimux-vcs-worktree-create"
                            (lambda ()
                              (%capture-worktree-operation-result repository
                                                                  (%create-worktree-command
                                                                   repository
                                                                   branch
                                                                   path
                                                                   start-point
                                                                   force)
                                                                  generation))
                            (lambda (operation-result)
                              (%apply-created-worktree repository
                                                       operation-result))
                            on-complete
                            on-error
                            callback-dispatch on-start)))
(defstruct worktree-delete-result
  (removed-p nil)
  error
  refresh-error)

(defun delete-worktree-async (worktree &key force before-delete on-complete
                                         on-error on-result on-start callback-dispatch)
  "ON-RESULT receives the removal receipt instead of the legacy callbacks.
Observer errors do not change the recorded outcome of Git removal."
  (let ((generation (%begin-worktree-request worktree)))
    (cl-concurrent-kit:make-thread
   (lambda ()
     (%dispatch-callback callback-dispatch on-start)
     (let ((receipt (make-worktree-delete-result))
           (snapshot nil)
           (repository nil)
           (settled-p nil))
       (handler-case
           (progn
             (when before-delete (funcall before-delete))
             (setf repository (%delete-worktree-command worktree force)
                   (worktree-delete-result-removed-p receipt) t)
             (handler-case
                 (setf snapshot (%capture-worktree-operation-result repository t generation))
               (error (condition)
                 (setf (worktree-delete-result-refresh-error receipt) condition))))
         (error (condition)
           (setf (worktree-delete-result-error receipt) condition)))
       (%dispatch-callback
        callback-dispatch
        (lambda ()
          (unless settled-p
            (setf settled-p t)
            (when snapshot
              (handler-case (%apply-worktree-operation-result snapshot)
                (error (condition)
                  (setf (worktree-delete-result-refresh-error receipt) condition))))
            (cond
              (on-result (funcall on-result receipt))
              ((or (worktree-delete-result-error receipt)
                   (worktree-delete-result-refresh-error receipt))
               (when on-error
                 (funcall on-error (or (worktree-delete-result-error receipt)
                                       (worktree-delete-result-refresh-error receipt)))))
              (on-complete
               (handler-case (funcall on-complete t)
                 (error (condition)
                   (when on-error (funcall on-error condition)))))))))
       receipt))
   :name "nerimux-vcs-worktree-delete")))
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
  (let ((generation (%begin-worktree-request repository)))
    (%run-vcs-operation-async "nerimux-vcs-worktree-prune"
                            (lambda ()
                              (let ((worker-result
                                     (%prune-worktrees-command repository
                                                               dry-run
                                                               verbose)))
                                (%capture-worktree-operation-result
                                 (first worker-result)
                                 (second worker-result) generation)))
                            (lambda (operation-result)
                              (%apply-worktree-operation-result
                               operation-result))
                            on-complete
                            on-error
                            callback-dispatch)))

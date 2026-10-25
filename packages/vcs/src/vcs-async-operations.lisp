(in-package #:nerimux/vcs)

(defun scan-repositories-async (&key query
                                     on-start
                                     on-complete
                                     on-error
                                     on-progress
                                     callback-dispatch)
  "Run SCAN-REPOSITORIES on a worker thread and return its thread handle.
   ON-PROGRESS (FR-004b) is dispatched through CALLBACK-DISPATCH exactly like
   ON-COMPLETE/ON-ERROR -- it runs on the worker thread inside
   SCAN-REPOSITORIES, so it must cross the same boundary before touching any
   UI state the event loop owns."
  (cl-concurrent-kit:make-thread
   (lambda ()
     (%dispatch-callback callback-dispatch on-start)
     (scan-repositories :query
                        query
                        :on-progress
                        (and on-progress
                             (lambda (count)
                               (%dispatch-callback callback-dispatch
                                                   on-progress
                                                   count)))
                        :on-complete
                        (lambda (organizations)
                          (%dispatch-callback callback-dispatch
                                              on-complete
                                              organizations))
                        :on-error
                        (lambda (condition)
                          (%dispatch-callback callback-dispatch
                                              on-error
                                              condition))))
   :name
   "nerimux-vcs-scan"))

(defstruct (%repository-status-generation
            (:constructor %make-repository-status-generation ()))
  (pending 0))

(defvar *repository-status-generations* (make-hash-table :test #'eq))

(defconstant +repository-status-worker-limit+
  8
  "Status reads allowed to run at once.  Each one forks several `git`
   processes, so a worker per repository exhausts the process file-descriptor
   limit on a ghq root holding hundreds of repositories.")
(defun %emit-vcs-diagnostic (logger level message fields)
  "Prevent a diagnostic sink failure from stopping request settlement."
  (handler-case
      (log-kit:emit-log logger level message fields)
    (error () nil)))

(defun %begin-repository-status-generation (repository)
  (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
    (let ((entry
            (or (gethash repository *repository-status-generations*)
                (setf (gethash repository *repository-status-generations*)
                      (%make-repository-status-generation)))))
      (incf (%repository-status-generation-pending entry))
      (values entry (%begin-repository-data-generation repository)))))

(defun refresh-repositories-async (repositories &key
                                                on-start
                                                on-repository
                                                on-complete
                                                on-error
                                                (status-reader
                                                 #'%read-repository-status)
                                                (status-applier
                                                 #'%apply-repository-status)
                                                callback-dispatch)
  "Read each repository on a worker and apply its status through the dispatcher.
   Generation registration and status application serialize per repository identity;
   an older captured success is discarded even while its successor is pending.
   Operation errors and completion callbacks still settle every request.
   ON-COMPLETE receives REPOSITORIES itself, once every request has settled --
   in the order given, not reordered by which worker happens to finish last.
   REFRESH-WORKSPACE-STATUS-ASYNC below wraps this ON-COMPLETE to hand its own
   caller ORGANIZATIONS instead, for exactly that reason.
   Every repository is registered for its generation before any read starts;
   at most +REPOSITORY-STATUS-WORKER-LIMIT+ workers then drain that queue, so
   the returned thread list is the pool, not one thread per repository."
  (let* ((repositories (copy-list repositories))
         (remaining (length repositories))
         (queue-lock (cl-concurrent-kit:make-lock :name "vcs status queue"))
         (queue nil)
         (threads nil))
    (labels ((complete-one (repository entry)
               (let ((complete-p
                       (sb-thread:with-recursive-lock
                           (*workspace-catalog-generation-lock*)
                         (when (zerop (decf (%repository-status-generation-pending entry)))
                           (remhash repository *repository-status-generations*))
                         (zerop (decf remaining)))))
                 (when (and complete-p on-complete)
                   (funcall on-complete repositories))))
             (fail-one (repository entry condition)
               (unwind-protect 
                   (if on-error
                       (funcall on-error repository condition)
                       (error condition))
                 (complete-one repository entry)))
             (apply-one (repository entry token update)
               (let ((condition
                      (handler-case (progn
                                      (sb-thread:with-recursive-lock
                                          (*workspace-catalog-generation-lock*)
                                        (when (%repository-data-generation-current-p
                                               repository token :before-apply t)
                                          (funcall status-applier repository update)
                                          (when (and on-repository
                                                     (%repository-data-generation-current-p
                                                      repository token))
                                            (funcall on-repository repository))))
                                      nil)
                        (error (caught)
                          caught))))
                 (if condition
                     (fail-one repository entry condition)
                     (complete-one repository entry))))
             (next-request ()
               (cl-concurrent-kit:with-lock-held (queue-lock) (pop queue)))
             (read-one (repository entry token)
               (%dispatch-callback callback-dispatch on-start repository)
               (multiple-value-bind (update condition)
                   (handler-case (values (funcall status-reader repository)
                                         nil)
                     (error (caught)
                       (values nil caught)))
                 (if condition
                     (%dispatch-callback callback-dispatch
                                         #'fail-one
                                         repository
                                         entry
                                         condition)
                     (%dispatch-callback callback-dispatch
                                         #'apply-one
                                         repository
                                         entry
                                         token
                                         update))))
             (drain ()
               (loop for request = (next-request)
                     while request
                     ;; The workers are shared, so a condition escaping one
                     ;; request would strand every repository queued behind
                     ;; it; dropping it here instead of settling it through
                     ;; FAIL-ONE left REMAINING stuck above zero and
                     ;; ON-COMPLETE never firing for the batch.
                     do (handler-case (apply #'read-one request)
                          (error (caught)
                            (destructuring-bind (repository entry token) request
                              (declare (ignore token))
                              (fail-one repository entry caught)))))))
      (if (null repositories)
          (progn
            (%dispatch-callback callback-dispatch on-complete repositories)
            nil)
          (progn
            (setf queue
                  (loop for repository in repositories
                        collect (multiple-value-bind (entry token)
                                    (%begin-repository-status-generation
                                     repository)
                                  (list repository entry token))))
            (dotimes (index
                      (min +repository-status-worker-limit+
                           (length repositories))
                      (nreverse threads))
              (push (cl-concurrent-kit:make-thread
                     #'drain
                     :name (format nil "nerimux-vcs-status-~D" index))
                    threads)))))))

(defparameter *workspace-worktree-status-worker-limit*
  64
  "Worker threads created for each refresh. A process-wide semaphore limits simultaneous status readers to the capacity set when the process first creates it. Changing this value later changes per-refresh pool sizes only; restart to change that capacity.")
(defvar *workspace-worktree-status-reader-semaphore*
  (sb-thread:make-semaphore :count *workspace-worktree-status-worker-limit*))
(defconstant +repository-worktree-status-worker-limit+
  4
  "Maximum concurrent worktree status readers within one repository request.")

(defconstant +workspace-status-preparation-worker-limit+
  4
  "Maximum concurrent repository stash preparation steps.")

(defstruct (%workspace-status-request
            (:constructor %make-workspace-status-request
                (repository entry token worktrees updates failures active-readers)))
  repository
  entry
  token
  worktrees
  updates
  failures
  active-readers
  stashes
  preparation-condition
  (next-index 0)
  (active 0)
  (failed-p nil)
  (stale-p nil)
  (prepared-p nil)
  (ready-queued-p nil)
  (settled-p nil)
  (workers-settled-p nil))

;; Worker threads do not inherit dynamic catalog bindings from the caller.
(defun %repository-data-generation-worker-current-p (repository generation)
  (and (eq generation (gethash repository *repository-data-generations*))
       (eq *workspace-catalog-generation*
           (%repository-data-generation-catalog-generation generation))))

(defun %refresh-repositories-with-worktree-queue (repositories &key
                                                               on-start
                                                               on-repository
                                                               on-complete
                                                               on-error
                                                               (status-applier
                                                                #'%apply-repository-status)
                                                               callback-dispatch)
  (let* ((repositories (copy-list repositories))
         (test-environment-update *worktree-test-environment-update*)
         (remaining (length repositories)))
    (if (null repositories)
        (progn
          (%dispatch-callback callback-dispatch on-complete repositories)
          nil)
        (let* ((queue-lock
                 (cl-concurrent-kit:make-lock :name "workspace worktree status queue"))
               (status-available (sb-thread:make-semaphore :count 0))
               (preparation-queue nil)
               (ready-front nil)
               (ready-back nil)
               (status-workers-stopping-p nil)
               (worktree-count 0) (pending-worker-requests (length repositories))
               (requests
                 (loop for repository in repositories
                       collect
                         (multiple-value-bind (entry token)
                             (%begin-repository-status-generation repository)
                           (let* ((worktrees
                                    (coerce
                                     (nerimux/workspace-model:repository-worktrees
                                      repository)
                                     'vector))
                                  (count (length worktrees)))
                             (incf worktree-count count)
                             (%make-workspace-status-request repository entry token worktrees
                              (make-array count :initial-element nil)
                              (make-array count :initial-element nil)
                              (make-array count :initial-element nil))))))
               (status-thread-count
                 (min *workspace-worktree-status-worker-limit* worktree-count))
               (preparation-thread-count
                 (min +workspace-status-preparation-worker-limit+
                      (length repositories)))
               (threads nil))
          (setf preparation-queue requests)
          (labels ((pop-ready-under-lock ()
                     (unless ready-front
                       (setf ready-front (nreverse ready-back)
                             ready-back nil))
                     (pop ready-front))
                   (request-ready-to-settle-p (request)
                     (and (%workspace-status-request-prepared-p request)
                          (zerop (%workspace-status-request-active request))
                          (or (%workspace-status-request-failed-p request)
                              (%workspace-status-request-stale-p request)
                              (= (%workspace-status-request-next-index request)
                                 (length (%workspace-status-request-worktrees request))))
                          (not (%workspace-status-request-settled-p request))))
                   (queue-ready-request-under-lock (request)
                     (when (and (%workspace-status-request-prepared-p request)
                                (not (%workspace-status-request-failed-p request))
                                (not (%workspace-status-request-stale-p request))
                                (not (%workspace-status-request-ready-queued-p request))
                                (< (%workspace-status-request-active request)
                                   +repository-worktree-status-worker-limit+)
                                (< (%workspace-status-request-next-index request)
                                   (length (%workspace-status-request-worktrees request))))
                       ;; Keep the queue and semaphore count in sync if publishing fails.
                       (setf (%workspace-status-request-ready-queued-p request) t)
                       (push request ready-back)
                       (handler-case
                           (sb-thread:signal-semaphore status-available)
                         (error (condition)
                           (pop ready-back)
                           (setf (%workspace-status-request-ready-queued-p request) nil)
                           (error condition)))))
                   (request-condition (request)
                     (or (%workspace-status-request-preparation-condition request)
                         (loop for index below
                               (length (%workspace-status-request-failures request))
                               for condition =
                                 (aref (%workspace-status-request-failures request)
                                       index)
                               when condition
                                 return condition)))
                   (stop-status-workers ()
                     (let ((stop-p nil))
                       (cl-concurrent-kit:with-lock-held (queue-lock)
                         (unless status-workers-stopping-p
                           (setf status-workers-stopping-p t
                                 stop-p t)))
                       (when stop-p
                         (dotimes (index status-thread-count)
                           (declare (ignore index))
                           (sb-thread:signal-semaphore status-available)))))
                   (maybe-stop-status-workers ()
                     (when (cl-concurrent-kit:with-lock-held (queue-lock)
                             (and (zerop pending-worker-requests)
                                  (not status-workers-stopping-p)))
                       (stop-status-workers)))
                   (complete-one (repository entry)
                     (let ((complete-p
                             (sb-thread:with-recursive-lock
                                 (*workspace-catalog-generation-lock*)
                               (when (zerop
                                      (decf
                                       (%repository-status-generation-pending
                                        entry)))
                                 (remhash repository
                                          *repository-status-generations*))
                               (zerop (decf remaining)))))
                       (when (and complete-p on-complete)
                         (funcall on-complete repositories))))
                   (fail-one (repository entry condition)
                     (unwind-protect
                          (if on-error
                              (funcall on-error repository condition)
                              (error condition))
                       (complete-one repository entry)))
                   (apply-one (repository entry token update)
                     (let ((condition
                             (handler-case
                                 (progn
                                   (sb-thread:with-recursive-lock
                                       (*workspace-catalog-generation-lock*)
                                     (when (%repository-data-generation-current-p
                                            repository token :before-apply t)
                                       (funcall status-applier repository update)
                                       (when (and on-repository
                                                  (%repository-data-generation-current-p
                                                   repository token))
                                         (funcall on-repository repository))))
                                   nil)
                               (error (caught)
                                 caught))))
                       (if condition
                           (fail-one repository entry condition)
                           (complete-one repository entry))))
                   (settle-request (request)
                      (let ((worker-settlement-p nil))
                        (cl-concurrent-kit:with-lock-held (queue-lock)
                          (unless (%workspace-status-request-workers-settled-p request)
                            (setf (%workspace-status-request-workers-settled-p request) t
                                  worker-settlement-p t)
                            (decf pending-worker-requests)))
                        (when worker-settlement-p
                          (maybe-stop-status-workers)
                          (let* ((repository
                                   (%workspace-status-request-repository request))
                                 (entry (%workspace-status-request-entry request))
                                 (condition (request-condition request))
                                 (dispatch-state :pending)
                                 (callback (if condition #'fail-one #'apply-one))
                                 (arguments
                                   (if condition
                                       (list repository entry condition)
                                       (list repository
                                             entry
                                             (%workspace-status-request-token request)
                                             (coerce
                                              (%workspace-status-request-updates request)
                                              'list)))))
                            (handler-case
                                (%dispatch-callback
                                 callback-dispatch
                                 (lambda ()
                                   (let ((run-p nil))
                                     (cl-concurrent-kit:with-lock-held (queue-lock)
                                       (when (eq dispatch-state :pending)
                                         (setf dispatch-state :running
                                               run-p t)))
                                     (when run-p
                                       (apply callback arguments)))))
                              (error (caught)
                                (let ((fallback-p nil))
                                  (cl-concurrent-kit:with-lock-held (queue-lock)
                                    (when (eq dispatch-state :pending)
                                      (setf dispatch-state :fallback
                                            fallback-p t)))
                                  (if fallback-p
                                      (fail-one repository entry caught)
                                      (error caught))))))))
                    )
                   (mark-request-ready (request stashes condition)
                      (let ((settle-p nil))
                        (cl-concurrent-kit:with-lock-held (queue-lock)
                          (setf (%workspace-status-request-stashes request) stashes
                                (%workspace-status-request-prepared-p request) t)
                          (when condition
                            (setf (%workspace-status-request-failed-p request) t
                                  (%workspace-status-request-preparation-condition request) condition))
                          (unless condition
                            (queue-ready-request-under-lock request))
                          (when (request-ready-to-settle-p request)
                            (setf (%workspace-status-request-settled-p request) t
                                  settle-p t)))
                        (when settle-p
                          (settle-request request))))
                   (fail-preparation-request (request condition)
                      (let ((settle-p nil))
                        (cl-concurrent-kit:with-lock-held (queue-lock)
                          (unless (%workspace-status-request-workers-settled-p request)
                            (setf (%workspace-status-request-stashes request) nil
                                  (%workspace-status-request-prepared-p request) t
                                  (%workspace-status-request-failed-p request) t
                                  (%workspace-status-request-preparation-condition request) condition
                                  (%workspace-status-request-settled-p request) nil)
                            (when (request-ready-to-settle-p request)
                              (setf (%workspace-status-request-settled-p request) t
                                    settle-p t))))
                        (when settle-p
                          (settle-request request))))
                   (next-preparation-request ()
                     (cl-concurrent-kit:with-lock-held (queue-lock)
                       (pop preparation-queue)))
                   (prepare-repositories ()
                      (loop for request = (next-preparation-request)
                            while request
                            do (handler-case
                                   (handler-case
                                       (let ((stashes nil)
                                             (condition nil))
                                         (handler-case
                                             (progn
                                               (%dispatch-callback
                                                callback-dispatch
                                                on-start
                                                (%workspace-status-request-repository request))
                                               (setf stashes
                                                     (%repository-status-shared-stashes
                                                      (%workspace-status-request-repository request))))
                                           (error (caught)
                                             (setf condition caught)))
                                         (mark-request-ready request stashes condition))
                                     (error (caught)
                                       (unwind-protect
                                            (%emit-vcs-diagnostic
                                             *vcs-diagnostic-logger*
                                             log-kit:+level-warn+
                                             "Workspace status preparation failed"
                                             (list :repository
                                                   (nerimux/workspace-model:repository-specification
                                                     (%workspace-status-request-repository request))
                                                   :condition (princ-to-string caught)))
                                         (fail-preparation-request request caught)))
                                 (error (settlement-error)
                                   (unwind-protect
                                        (%emit-vcs-diagnostic
                                         *vcs-diagnostic-logger*
                                         log-kit:+level-warn+
                                         "Workspace status settlement failed"
                                         (list :repository
                                               (nerimux/workspace-model:repository-specification
                                                 (%workspace-status-request-repository request))
                                               :condition (princ-to-string settlement-error)))
                                     (fail-preparation-request request settlement-error))))))
                    )
                   (next-worktree-request ()
                     (sb-thread:wait-on-semaphore status-available)
                     (let ((work nil)
                           (request-to-settle nil)
                           (stop-p nil))
                       (cl-concurrent-kit:with-lock-held (queue-lock)
                         (if status-workers-stopping-p
                             (setf stop-p t)
                             (let ((request (pop-ready-under-lock)))
                               (when request
                                 (setf (%workspace-status-request-ready-queued-p request)
                                       nil)
                                 (unless (or
                                          (%workspace-status-request-failed-p request)
                                          (%workspace-status-request-stale-p request))
                                   (when (and
                                          (< (%workspace-status-request-active request)
                                             +repository-worktree-status-worker-limit+)
                                          (< (%workspace-status-request-next-index request)
                                             (length
                                              (%workspace-status-request-worktrees
                                               request))))
                                     (let* ((index
                                              (%workspace-status-request-next-index request))
                                            (worktree
                                              (aref
                                               (%workspace-status-request-worktrees request)
                                               index)))
                                       (incf (%workspace-status-request-next-index request))
                                       (incf (%workspace-status-request-active request))
                                       (setf
                                        (aref
                                         (%workspace-status-request-active-readers request)
                                         index)
                                        t)
                                       (queue-ready-request-under-lock request)
                                       (setf work (list request index worktree)))))
                                 (when (request-ready-to-settle-p request)
                                   (setf (%workspace-status-request-settled-p request) t
                                         request-to-settle request))))))
                       (when request-to-settle
                         (settle-request request-to-settle))
                       (maybe-stop-status-workers)
                       (or work (when stop-p :stop))))
                   (finish-worktree-request (request index update condition)
                     (let ((settle-p nil)
                           (handled-p nil))
                       (cl-concurrent-kit:with-lock-held (queue-lock)
                         (when
                             (aref
                              (%workspace-status-request-active-readers request)
                              index)
                           (setf handled-p t
                                 (aref
                                  (%workspace-status-request-active-readers request)
                                  index)
                                 nil)
                           (if condition
                               (setf
                                (aref (%workspace-status-request-failures request) index)
                                condition
                                (%workspace-status-request-failed-p request)
                                t)
                               (setf
                                (aref (%workspace-status-request-updates request) index)
                                update))
                           (decf (%workspace-status-request-active request))
                           (queue-ready-request-under-lock request)
                           (when (request-ready-to-settle-p request)
                             (setf (%workspace-status-request-settled-p request) t
                                   settle-p t))))
                       (when settle-p
                         (settle-request request))
                       (maybe-stop-status-workers)
                       handled-p))
                   (read-worktree-request (request index worktree)
                     (let ((reader-semaphore
                             *workspace-worktree-status-reader-semaphore*)
                           (stashes
                             (%workspace-status-request-stashes request))
                           (update nil)
                           (condition nil))
                       (handler-case
                           (progn
                             (sb-thread:wait-on-semaphore reader-semaphore)
                             (unwind-protect
                                 (if
                                  (sb-thread:with-recursive-lock
                                      (*workspace-catalog-generation-lock*)
                                    (%repository-data-generation-worker-current-p
                                     (%workspace-status-request-repository request)
                                     (%workspace-status-request-token request)))
                                  (setf update
                                        (if stashes
                                            (%read-worktree-status
                                             worktree :stashes stashes)
                                            (%read-worktree-status worktree)))
                                  (cl-concurrent-kit:with-lock-held (queue-lock)
                                    (setf (%workspace-status-request-stale-p request) t
                                          (%workspace-status-request-next-index request)
                                          (length
                                           (%workspace-status-request-worktrees request)))))
                               (sb-thread:signal-semaphore reader-semaphore)))
                         (error (caught)
                           (setf condition caught)))
                       (finish-worktree-request request index update condition)))
                   (read-worktrees ()
                     (loop for work = (next-worktree-request)
                           until (eq work :stop)
                           when work
                             do (handler-case
                                    (apply #'read-worktree-request work)
                                  (error (caught)
                                    (let ((recovered-p
                                            (destructuring-bind
                                                (request index worktree)
                                                work
                                              (declare (ignore worktree))
                                              (finish-worktree-request
                                               request index nil caught))))
                                      (unless recovered-p
                                        (error caught))))))))
            (dotimes (index preparation-thread-count)
              (push (cl-concurrent-kit:make-thread
                     (lambda ()
                       (let ((*worktree-test-environment-update*
                               test-environment-update))
                         (prepare-repositories)))
                     :name (format nil "nerimux-vcs-status-prep-~D" index))
                    threads))
            (dotimes (index status-thread-count)
              (push (cl-concurrent-kit:make-thread
                     (lambda ()
                       (let ((*worktree-test-environment-update*
                               test-environment-update))
                         (read-worktrees)))
                     :name (format nil "nerimux-vcs-worktree-status-~D" index))
                    threads))
            (nreverse threads))))))
(defun refresh-workspace-status-async (&key
                                       (organizations *workspace-organizations*)
                                       on-start
                                       on-repository
                                       on-complete
                                       on-error
                                       (status-reader #'%read-repository-status)
                                       (status-applier
                                        #'%apply-repository-status)
                                       callback-dispatch)
  "Refresh all catalog repositories concurrently without blocking the UI.
   ON-COMPLETE receives ORGANIZATIONS, not the flattened repository list
   REFRESH-REPOSITORIES-ASYNC completes with: every workspace-level caller
   feeds the argument to organization-consuming code (picker items, tree
   rebind), and handing it repositories type-errors on the first access."
  (let* ((repositories
           (loop for organization in organizations
                 append
                   (nerimux/workspace-model:organization-repositories
                    organization)))
         (workspace-complete
           (and on-complete
                (lambda (completed-repositories)
                  (declare (ignore completed-repositories))
                  (funcall on-complete organizations)))))
    (if (eq status-reader #'%read-repository-status)
        (%refresh-repositories-with-worktree-queue
         repositories
         :on-repository on-repository
         :on-start on-start
         :on-complete workspace-complete
         :on-error on-error
         :status-applier status-applier
         :callback-dispatch callback-dispatch)
        (refresh-repositories-async
         repositories
         :on-repository on-repository
         :on-start on-start
         :on-complete workspace-complete
         :on-error on-error
         :status-reader status-reader
         :status-applier status-applier
         :callback-dispatch callback-dispatch))))

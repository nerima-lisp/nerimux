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
  (refresh-repositories-async
   (loop for organization in organizations
         append (nerimux/workspace-model:organization-repositories organization))
   :on-repository
   on-repository
   :on-start on-start
   :on-complete
   (and on-complete
        (lambda (repositories)
          (declare (ignore repositories))
          (funcall on-complete organizations)))
   :on-error
   on-error
   :status-reader
   status-reader
   :status-applier
   status-applier
   :callback-dispatch
   callback-dispatch))

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
   ON-COMPLETE receives REPOSITORIES itself, once every worker has settled --
   in the order given, not reordered by which worker happens to finish last.
   REFRESH-WORKSPACE-STATUS-ASYNC below wraps this ON-COMPLETE to hand its own
   caller ORGANIZATIONS instead, for exactly that reason."
  (let* ((repositories (copy-list repositories))
         (remaining (length repositories))
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
                     (complete-one repository entry)))))
      (if (null repositories)
          (progn
            (%dispatch-callback callback-dispatch on-complete repositories)
            nil)
          (progn
            (dolist (repository repositories (nreverse threads))
              (multiple-value-bind (entry token)
                  (%begin-repository-status-generation repository)
                (let ((current repository))
                  (push
                   (cl-concurrent-kit:make-thread
                    (lambda ()
                      (%dispatch-callback callback-dispatch on-start current)
                      (multiple-value-bind (update condition)
                          (handler-case (values (funcall status-reader current)
                                                nil)
                            (error (caught)
                              (values nil caught)))
                        (if condition
                            (%dispatch-callback callback-dispatch
                                                #'fail-one
                                                current
                                                entry
                                                condition)
                            (%dispatch-callback callback-dispatch
                                                #'apply-one
                                                current
                                                entry
                                                token
                                                update))))
                    :name
                    (format nil
                            "nerimux-vcs-status-~A"
                            (nerimux/workspace-model:repository-id current)))
                   threads)))))))))

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

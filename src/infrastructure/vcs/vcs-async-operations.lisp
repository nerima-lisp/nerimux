(in-package #:nerimux/vcs)

(defun scan-repositories-async
    (&key query on-complete on-error callback-dispatch)
  "Run SCAN-REPOSITORIES on a worker thread and return its thread handle."
  (cl-concurrent-kit:make-thread
   (lambda ()
     (scan-repositories :query query
                        :on-complete
                        (lambda (organizations)
                          (%dispatch-callback callback-dispatch on-complete
                                              organizations))
                        :on-error
                        (lambda (condition)
                          (%dispatch-callback callback-dispatch on-error
                                              condition))))
   :name "nerimux-vcs-scan"))

(defun refresh-repositories-async
    (repositories &key on-repository on-complete on-error
                            (status-reader #'%read-repository-status)
                            (status-applier #'%apply-repository-status)
                            callback-dispatch)
  "Read each repository on a worker and apply its status through the dispatcher."
  (let* ((repositories (copy-list repositories))
         (remaining (cl-concurrent-kit:make-atomic-counter
                     (length repositories)))
         (threads nil))
    (labels ((complete-one ()
               (cl-concurrent-kit:atomic-counter-decf remaining)
               (when (zerop (cl-concurrent-kit:atomic-counter-value remaining))
                 (when on-complete
                   (funcall on-complete repositories))))
             (fail-one (repository condition)
               (unwind-protect
                    (if on-error
                        (funcall on-error repository condition)
                        (error condition))
                 (complete-one)))
             (apply-one (repository update)
               (let ((condition
                       (handler-case
                           (progn
                             (funcall status-applier repository update)
                             (when on-repository
                               (funcall on-repository repository))
                             nil)
                         (error (caught)
                           caught))))
                 (if condition
                     (fail-one repository condition)
                     (complete-one)))))
      (if (null repositories)
          (progn
            (%dispatch-callback callback-dispatch on-complete repositories)
            nil)
          (progn
            (dolist (repository repositories (nreverse threads))
              (let ((current repository))
                (push
                 (cl-concurrent-kit:make-thread
                  (lambda ()
                    (multiple-value-bind (update condition)
                        (handler-case
                            (values (funcall status-reader current) nil)
                          (error (caught)
                            (values nil caught)))
                      (if condition
                          (%dispatch-callback callback-dispatch #'fail-one current
                                              condition)
                          (%dispatch-callback callback-dispatch #'apply-one current
                                              update))))
                  :name (format nil "nerimux-vcs-status-~A"
                                (nerimux/model:repository-id current)))
                 threads))))))))

(defun refresh-workspace-status-async
    (&key (organizations *workspace-organizations*) on-repository on-complete
          on-error (status-reader #'%read-repository-status)
          (status-applier #'%apply-repository-status)
          callback-dispatch)
  "Refresh all catalog repositories concurrently without blocking the UI."
  (refresh-repositories-async
   (loop for organization in organizations
         append (nerimux/model:organization-repositories organization))
   :on-repository on-repository
   :on-complete on-complete
   :on-error on-error
   :status-reader status-reader
   :status-applier status-applier
   :callback-dispatch callback-dispatch))

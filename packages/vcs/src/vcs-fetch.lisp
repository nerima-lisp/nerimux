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

(defun fetch-repository (repository)
  "Fetch REPOSITORY's remotes with git fetch, then refresh its status."
  (unless repository
    (error "A repository is required to fetch."))
  (vcs-kit:vcs-fetch (%repository-backend repository))
  (refresh-repository-status repository)
  repository)

(defun %read-fetched-repository-status (repository)
  (vcs-kit:vcs-fetch (%repository-backend repository))
  (%read-repository-status repository))

(defun fetch-repository-async (repository &key
                                          on-complete
                                          on-error
                                          callback-dispatch)
  "Fetch REPOSITORY once and dispatch its completion or failure callback.

A duplicate request made while the same repository is in flight completes
with NIL without starting another worker."
  (let ((key
         (list :repository (nerimux/workspace-model:repository-id repository))))
    (if (%fetch-begin key)
        (first
         (refresh-repositories-async (list repository)
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
                                     callback-dispatch))
        (progn
          (%dispatch-callback callback-dispatch on-complete nil)
          nil))))

(defun fetch-organization-async (organization &key
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
        (refresh-repositories-async
         (nerimux/workspace-model:organization-repositories organization)
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
         callback-dispatch)
        (progn
          (%dispatch-callback callback-dispatch on-complete nil)
          nil))))

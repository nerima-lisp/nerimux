(in-package #:nerimux)

;;;; Mutable data owned by the single multi-client event loop.
(defvar *clients* nil)
(defvar *main-thread-callback-lock*
  (cl-concurrent-kit:make-lock :name "nerimux-main-thread-callbacks"))
(defvar *main-thread-callbacks* nil)
(defvar *workspace-catalog-refresh-started-p* nil)
(defvar *workspace-collapsed-node-ids* (make-hash-table :test #'equal))
(defvar *workspace-refreshing-ids* (make-hash-table :test #'equal))
(defvar *workspace-stale-ids* (make-hash-table :test #'equal))
(defvar *workspace-worktree-last-pane* (make-hash-table :test #'equal))
(defvar *workspace-catalog-loaded-p* nil)
(defvar *workspace-scan-progress* nil)

(defun %enqueue-main-thread-callback (thunk)
  "Queue THUNK for execution by the multi-client event loop."
  (check-type thunk function)
  (cl-concurrent-kit:with-lock-held (*main-thread-callback-lock*)
    (push thunk *main-thread-callbacks*))
  nil)

(defun %drain-main-thread-callbacks ()
  "Run callbacks queued by worker threads, keeping one failure local."
  (let ((callbacks
          (cl-concurrent-kit:with-lock-held (*main-thread-callback-lock*)
            (prog1 (nreverse *main-thread-callbacks*)
              (setf *main-thread-callbacks* nil)))))
    (dolist (callback callbacks)
      (handler-case
          (funcall callback)
        (error (condition)
          (format *error-output* "~&nerimux main-thread callback failed: ~A~%"
                  condition)
          (finish-output *error-output*)))))
  nil)

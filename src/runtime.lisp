(in-package #:nerimux)

(defun %mark-dirty ()
  "Set the shared redraw flag."
  (setf *dirty* t))

(defun %join-thread-with-timeout (thread &optional
                                         (timeout +reader-thread-join-timeout+))
  "Join THREAD, waiting at most TIMEOUT seconds."
  (sb-thread:join-thread thread :timeout timeout))

(defmacro with-channel-plist ((lk cv ch) &body body)
  "Bind LK and CV to the :lock and :cv fields of the channel plist CH."
  (let ((ch-var (gensym "CH")))
    `(let* ((,ch-var ,ch)
            (,lk (getf ,ch-var :lock))
            (,cv (getf ,ch-var :cv)))
       ,@body)))

(defun %ensure-channel (name)
  "Return the plist for channel NAME, creating it if absent."
  (or (gethash name *wait-channels*)
      (let* ((lk (make-lock :name (format nil "wf-~A" name)))
             (cv (make-condition-variable :name (format nil "wf-cv-~A" name)))
             (ch (list :lock lk :cv cv :locked nil)))
        (setf (gethash name *wait-channels*) ch)
        ch)))

(defun wait-for-channel (name)
  "Block the calling thread until channel NAME is signaled, or until
   +wait-for-channel-timeout+ seconds elapse.  Returns T if signaled, NIL
   on timeout.  A bounded wait prevents indefinite blocking when the
   corresponding signal-channel is never called."
  (with-channel-plist (lk cv (%ensure-channel name))
                      (with-lock-held (lk)
                                      (condition-wait cv
                                                      lk
                                                      :timeout
                                                      +wait-for-channel-timeout+))))

(defun signal-channel (name)
  "Signal all threads blocked on channel NAME."
  (let ((ch (%ensure-channel name)))
    (unless (getf ch :locked)
      (with-channel-plist (lk cv ch)
                          (with-lock-held (lk) (condition-notify cv))))))

(defun %set-channel-locked (name locked-p)
  "Set the :locked flag on channel NAME."
  (let ((ch (%ensure-channel name)))
    (setf (getf ch :locked) locked-p)))

(defun lock-channel (name)
  "Lock channel NAME so signal-channel is suppressed (a no-op) until unlocked.
   While a channel is locked, any call to signal-channel for the same NAME
   checks the :locked flag and skips the condition-notify entirely.  This
   allows callers to temporarily block notifications without losing them
   permanently — the channel is not destroyed, only silenced."
  (%set-channel-locked name t))

(defun unlock-channel (name)
  "Unlock channel NAME, allowing subsequent signal-channel calls to notify waiters.
   Paired with lock-channel: once unlocked, signal-channel will again call
   condition-notify on the channel's condition variable.  Does not retroactively
   deliver signals that were suppressed while the channel was locked."
  (%set-channel-locked name nil))

(defun install-sigwinch-handler ()
  "Arm SIGWINCH so terminal resizes flag a one-shot relayout."
  (sb-sys:enable-interrupt sb-unix:sigwinch
                           (lambda (&rest ignored)
                             (declare (ignore ignored))
                             (setf *resize-pending* t
                                   *dirty* t))))

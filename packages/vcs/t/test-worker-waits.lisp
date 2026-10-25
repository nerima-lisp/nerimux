(in-package #:nerimux/test/vcs)

(defconstant +test-worker-timeout-seconds+
  60)

(defun %wait-for-test-worker (wait-function worker-description)
  (unless (funcall wait-function +test-worker-timeout-seconds+)
    (fail "Timed out after ~D seconds waiting for worker ~A"
          +test-worker-timeout-seconds+
          worker-description))
  t)

(defun %join-test-worker (thread worker-description)
  (%wait-for-test-worker
   (lambda (timeout-seconds)
     (let ((deadline
             (+ (get-internal-real-time)
                (round (* timeout-seconds internal-time-units-per-second)))))
       (loop
         (unless (sb-thread:thread-alive-p thread)
           (return t))
         (when (>= (get-internal-real-time) deadline)
           (return nil))
         (sleep 0.01))))
   worker-description)
  (sb-thread:join-thread thread :timeout 0)
  (expect (not (sb-thread:thread-alive-p thread)))
  thread)

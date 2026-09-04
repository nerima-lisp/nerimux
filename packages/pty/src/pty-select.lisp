(in-package #:nerimux/pty)
(defconstant +microseconds-per-second+ 1000000)
(defun %timeout-us-to-seconds (timeout-us)
  (when (>= timeout-us 0) (/ timeout-us +microseconds-per-second+)))
(defun %selectable-fds (fds)
  (remove-if-not (lambda (fd) (typep fd '(integer 0))) fds))
(defun select-fds (fds timeout-us)
  (let ((fds (%selectable-fds fds)))
    (when fds
      (handler-case (process-kit:wait-for-input fds :timeout
                                                (%timeout-us-to-seconds timeout-us))
        (process-kit:fd-wait-failed () nil)))))

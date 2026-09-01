;;;; POSIX environment-variable fixture for nerimux tests.
;;;;
;;;; Lives with nerimux-ports because ports is the lowest unit every consumer
;;;; can reach: model and pty both depend on it, and the root suite is above
;;;; everything. The overlay/prompt and config-directive macros this file was
;;;; named for were removed in R1 and R2; the name now matches the contents.
(in-package #:nerimux/test/ports)

(defmacro with-temporary-posix-environment-variable ((name value) &body body)
  "Bind NAME to VALUE in the real process environment for BODY and restore it."
  (let ((old-value (gensym "OLD")))
    `(let ((,old-value (ignore-errors (sb-ext:posix-getenv ,name))))
       (unwind-protect 
           (progn
             (if ,value
                 (ignore-errors (sb-posix:setenv ,name ,value 1))
                 (ignore-errors (sb-posix:unsetenv ,name)))
             ,@body)
         (if ,old-value
             (ignore-errors (sb-posix:setenv ,name ,old-value 1))
             (ignore-errors (sb-posix:unsetenv ,name)))))))

;;;; POSIX environment-variable fixture helper for nerimux tests.
;;;; (Overlay/prompt assertion macros that lived here were removed with the
;;;; overlay/prompt subsystem in R1; the config-directive assertion macros
;;;; that replaced them were removed with application/config in R2, since
;;;; APPLY-CONFIG-DIRECTIVE no longer exists.  See git history.  This file's
;;;; name no longer matches its contents -- a rename is proposed separately.)

(in-package #:nerimux/test)

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


;;;; Config-directive assertion and POSIX environment-variable fixture helpers
;;;; for nerimux tests.  (Overlay/prompt assertion macros that lived here were
;;;; removed with the overlay/prompt subsystem in R1; see git history.)

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

(defmacro assert-config-directive-rejected (form &optional (context "config directive"))
  "Assert that APPLY-CONFIG-DIRECTIVE rejects FORM and returns NIL."
  (declare (ignore context))
  `(expect (null (apply-config-directive ,form))))

(defmacro assert-config-directive-safe-nil (form &optional (context "config directive"))
  "Assert that APPLY-CONFIG-DIRECTIVE returns NIL without signaling."
  `(let ((result (handler-case (apply-config-directive ,form)
                   (error (e)
                     (fail "~A must not signal, got ~A" ,context e)
                     :signaled))))
     (expect (null result))))

(defmacro assert-config-directive-applied (form &optional (context "config directive"))
  "Assert that APPLY-CONFIG-DIRECTIVE returns T."
  (declare (ignore context))
  `(expect (eq t (apply-config-directive ,form))))


(in-package #:nerimux/test/model)

;;;; Session + process-environment fixtures.
;;;;
;;;; Split out of tests/helpers-process-fixtures.lisp when domain/model became
;;;; nerimux-model. Both build a session and set a real environment variable;
;;;; their only callers are the model session-environment tests.
(defmacro with-session-and-env-var ((sess-var name-var env-name env-value) &body
                                                                           body)
  "Bind SESS-VAR to a fresh empty session and NAME-VAR to ENV-NAME.
   Sets ENV-NAME to ENV-VALUE in the real process environment for the duration
   of BODY, then restores the old value (or unsets it if it was absent)."
  `(let ((,sess-var (make-session :id 1 :name "s"))
         (,name-var ,env-name))
     (with-temporary-posix-environment-variable (,name-var ,env-value) ,@body)))

(defmacro with-process-env-var ((name-var env-name env-value) &body body)
  "Bind NAME-VAR to ENV-NAME and set ENV-NAME to ENV-VALUE for BODY.
   Restores the original process environment entry after BODY exits."
  `(let ((,name-var ,env-name))
     (with-temporary-posix-environment-variable (,name-var ,env-value) ,@body)))

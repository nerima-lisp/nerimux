;;;; Session and window naming helpers for nerimux tests.

(in-package #:nerimux/test)

(defmacro with-registered-sessions ((&rest session-bindings) &body body)
  "Bind *SERVER-SESSIONS* from SESSION-BINDINGS data."
  `(let ((nerimux::*server-sessions*
          (list ,@(loop for (session-name session-var) in session-bindings
                        collect `(cons ,session-name ,session-var)))))
     ,@body))


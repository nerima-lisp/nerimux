(in-package #:nerimux/test)

(defmacro with-command-test-state ((sess) &body body)
  "Run BODY with a single-session server state and a clean dirty flag."
  `(let ((nerimux::*server-sessions* (list (cons "0" ,sess)))
         (nerimux::*dirty* nil))
     ,@body))

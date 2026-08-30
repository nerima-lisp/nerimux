(in-package #:nerimux/test)

;;;; Server-state fixture for command tests.
;;;;
;;;; Split out of helpers-screen-assertions.lisp when domain/terminal became
;;;; nerimux-terminal. It binds nerimux::*server-sessions* and nerimux::*dirty*,
;;;; which are BOOTSTRAP internals, so a terminal test system carrying it would
;;;; reach from DOMAIN to the top of the stack. Its one caller is a commands
;;;; test.

(defmacro with-command-test-state ((sess) &body body)
  "Run BODY with a single-session server state and a clean dirty flag."
  `(let ((nerimux::*server-sessions* (list (cons "0" ,sess)))
         (nerimux::*dirty* nil))
     ,@body))

(in-package #:nerimux/test)

;;;; Multi-client server test support (src/bootstrap/server-multi.lisp and
;;;; src/bootstrap/server-multi-loop.lisp).

(defun %make-test-conn (&key (rows 24) (cols 80))
  "A socket-less CLIENT-CONN for dispatch tests (paths that never touch the socket)."
  (nerimux::%make-client-conn :state (nerimux::make-input-state)
                              :rows rows :cols cols))

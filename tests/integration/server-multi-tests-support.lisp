(in-package #:nerimux/test)

;;;; Multi-client server test support (src/bootstrap/server-multi.lisp and
;;;; src/bootstrap/server-multi-loop.lisp).
(defun %make-test-conn (&key (rows 24) (cols 80))
  "A socket-less CLIENT-CONN for dispatch tests (paths that never touch the socket)."
  (nerimux::%make-client-conn :rows rows :cols cols))

(defmacro with-client-fd-reclamation ((session-var socket-label) &body body)
  "Run BODY against a client that closes, then assert its server stream is closed."
  `(with-fake-session (,session-var)
                      (with-test-listener
                       (listener path
                                 (%test-socket-path ,socket-label)
                                 :backlog
                                 4)
                       (let* ((nerimux::*clients* nil)
                              (client (connect-to path))
                              (server-sock (accept-connection listener)))
                         (unwind-protect 
                             (progn
                               (expect server-sock :to-be-truthy)
                               (let ((conn (nerimux::%add-client server-sock)))
                                 ,@body
                                 (loop repeat 100
                                       until (and
                                              (eq :quit
                                                  (nerimux::%multi-serve-iteration
                                                   listener
                                                   ,session-var))
                                              (null nerimux::*clients*))
                                       do (sleep 0.01))
                                 (expect (null nerimux::*clients*))
                                 (expect
                                  (not
                                   (open-stream-p
                                    (nerimux::client-conn-stream conn))))))
                           (ignore-errors (close-socket client)))))))

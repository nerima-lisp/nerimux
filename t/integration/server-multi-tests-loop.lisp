(in-package #:nerimux/test)

;;;; Listener and readiness handling for the multi-client server loop.

(describe "server-multi-suite"

  ;;; ── accept-pending-connection / dispatch-ready-clients ──────────────────────

  ;; %accept-pending-connection accepts and registers a new client when the
  ;; listener fd appears in READY.
  (it "accept-pending-connection-registers-client-when-listener-ready"
    (with-isolated-hooks
      (with-test-listener (listener path (%test-socket-path "accept-helper") :backlog 4)
        (let* ((listener-fd (nerimux/net:socket-fd listener))
               (nerimux::*clients* nil)
               (peer (nerimux/net:connect-to path)))
          (unwind-protect
               (progn
                 ;; Give the connection a moment to become acceptable.
                 (nerimux/pty:select-fds (list listener-fd) 1000000)
                 (nerimux::%accept-pending-connection listener listener-fd (list listener-fd))
                 (expect (= 1 (length nerimux::*clients*))))
            (ignore-errors (nerimux/net:close-socket peer)))))))

  ;; %accept-pending-connection does nothing when the listener fd is absent from
  ;; READY — no client is registered.
  (it "accept-pending-connection-noop-when-listener-not-ready"
    (with-isolated-hooks
      (with-test-listener (listener path (%test-socket-path "accept-helper-noop") :backlog 4)
        (let ((listener-fd (nerimux/net:socket-fd listener))
              (nerimux::*clients* nil))
          (nerimux::%accept-pending-connection listener listener-fd nil)
          (expect (null nerimux::*clients*))))))

  ;; %dispatch-ready-clients does not touch a client whose fd is absent from READY.
  (it "dispatch-ready-clients-skips-clients-not-in-ready-set"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-fd conn) 4242)
        (expect (null (nerimux::%dispatch-ready-clients s nil)))
        (expect (equal (list conn) nerimux::*clients*)))))

  ;; %dispatch-ready-clients drops a client whose stream yields EOF (a real closed
  ;; socket), removing it from *clients*.
  (it "dispatch-ready-clients-drops-client-on-eof"
    (with-isolated-hooks
      (with-fake-session (s)
        (with-test-listener (listener path (%test-socket-path "dispatch-helper") :backlog 4)
          (let* ((client      (nerimux/net:connect-to path))
                 (server-sock (nerimux/net:accept-connection listener))
                 (nerimux::*clients* nil))
            (when server-sock
              (let ((conn (nerimux::%add-client server-sock)))
                ;; Client half-closes: server-side read now sees EOF.
                (nerimux/net:close-socket client)
                (let ((ready (list (nerimux::client-conn-fd conn))))
                  (expect (null (nerimux::%dispatch-ready-clients s ready)))
                  (expect (null nerimux::*clients*)))))))))))

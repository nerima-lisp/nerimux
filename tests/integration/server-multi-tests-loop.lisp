(in-package #:nerimux/test)

;;;; Listener and readiness handling for the multi-client server loop.

(describe "server-multi-suite"

  ;;; ── accept-pending-connection / dispatch-ready-clients ──────────────────────

  ;; %accept-pending-connection accepts and registers a new client when the
  ;; listener fd appears in READY.
  (it "accept-pending-connection-registers-client-when-listener-ready"
    (progn
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
    (progn
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
    (progn
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
                  (expect (null nerimux::*clients*)))))))))) (it "dispatch-buffered-client-messages-stops-on-quit"
    (let ((conn (%make-test-conn)))
      (with-stubbed-fdefinition
          ((nerimux::%read-and-dispatch-client-message
            (lambda (session client)
              (declare (ignore session client))
              :quit)))
        (expect (eq :quit
                    (nerimux::%dispatch-buffered-client-messages
                     :session conn)))))) (it "dispatch-buffered-client-messages-stops-when-stream-has-no-buffered-input"
    (let ((conn (%make-test-conn)))
      (with-stubbed-fdefinition
          ((nerimux::%read-and-dispatch-client-message
            (lambda (session client)
              (declare (ignore session client))
              :handled)))
        (expect (null
                 (nerimux::%dispatch-buffered-client-messages
                  :session conn)))))) (it "dispatch-ready-clients-returns-quit-when-a-client-requests-shutdown"
    (let* ((conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (setf (nerimux::client-conn-fd conn) 4242)
      (with-stubbed-fdefinition
          ((nerimux::%dispatch-buffered-client-messages
            (lambda (session client)
              (declare (ignore session client))
              :quit)))
        (expect (eq :quit
                    (nerimux::%dispatch-ready-clients :session '(4242))))))) (it "dispatch-buffered-client-messages-treats-listen-error-as-no-buffered-input"
    (let* ((conn (%make-test-conn))
           (stream (make-string-input-stream "")))
      (close stream)
      (setf (nerimux::client-conn-stream conn) stream)
      (with-stubbed-fdefinition
          ((nerimux::%read-and-dispatch-client-message
            (lambda (session client)
              (declare (ignore session client))
              :handled)))
        (expect (null
                 (nerimux::%dispatch-buffered-client-messages
                  :session conn)))))) (it "multi-serve-iteration-dispatches-ready-listener-and-client"
    (let ((events nil))
      (with-stubbed-fdefinition
          ((nerimux::%drain-main-thread-callbacks (lambda () nil))
           (nerimux::%broadcast-frame (lambda (session) (declare (ignore session))))
           (nerimux/net::socket-fd (lambda (listener) (declare (ignore listener)) 7))
           (nerimux::%client-fds (lambda () (list 8)))
           (nerimux/pty::select-fds
            (lambda (fds timeout)
              (declare (ignore timeout))
              (push (list :select fds) events)
              (list 7 8)))
           (nerimux::%accept-pending-connection
            (lambda (listener fd ready)
              (declare (ignore listener fd ready))
              (push :accept events)
              nil))
           (nerimux::%dispatch-ready-clients
            (lambda (session ready)
              (declare (ignore session ready))
              (push :dispatch events)
              nil)))
        (expect (null (nerimux::%multi-serve-iteration :listener :session)))
        (expect (equal '(:dispatch :accept (:select (7 8))) events))))) (it "multi-serve-iteration-returns-nil-when-select-has-no-ready-fds"
    (let ((events nil))
      (with-stubbed-fdefinition
          ((nerimux::%drain-main-thread-callbacks
            (lambda () (push :drain events)))
           (nerimux::%broadcast-frame
            (lambda (session) (push (list :broadcast session) events)))
           (nerimux/net::socket-fd
            (lambda (listener) (declare (ignore listener)) 7))
           (nerimux/pty::select-fds
            (lambda (fds timeout)
              (push (list :select fds timeout) events)
              nil)))
        (expect (null (nerimux::%multi-serve-iteration :listener :session)))
        (expect (equal '((:select (7) 50000)
                         (:broadcast :session)
                         :drain)
                       events))))) (it "run-multi-server-loop-stops-on-quit-and-drops-all-clients"
    (let ((events nil)
          (first-call t)
          (conn-a (%make-test-conn))
          (conn-b (%make-test-conn))
          (nerimux::*running* t))
      (let ((nerimux::*clients* (list conn-a conn-b)))
        (with-stubbed-fdefinition
            ((nerimux::%multi-serve-iteration
              (lambda (listener session)
                (declare (ignore listener session))
                (push :iterate events)
                (when first-call
                  (setf first-call nil)
                  :quit)))
             (nerimux::%drop-client
              (lambda (conn &key bye)
                (push (list :drop conn bye) events))))
          (expect (null (nerimux::%run-multi-server-loop :listener :session)))
          (expect (null nerimux::*running*))
          (expect (= 1 (count :iterate events)))
          (expect (equal (list :drop conn-a t)
                         (find-if (lambda (event)
                                    (and (consp event)
                                         (eq :drop (first event))
                                         (eq conn-a (second event))))
                                  events)))
          (expect (equal (list :drop conn-b t)
                         (find-if (lambda (event)
                                    (and (consp event)
                                         (eq :drop (first event))
                                         (eq conn-b (second event))))
                                  events))))))))

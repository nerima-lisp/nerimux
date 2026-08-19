(in-package #:nerimux/test)

;;;; Multi-client server integration tests: command-client, exit policy, broadcast

(describe "server-multi-suite"

  ;;; -- Command client: forwards a command to the server ------------------------

  ;; A command the workspace UI does not recognize is rejected with a client
  ;; notification and NO reply frame.  This used to be the server side of the
  ;; `nerimux display -p` stdout channel: the command ran against the tmux
  ;; command table and its output came back as +msg-reply+.  That fallthrough
  ;; was removed with the tmux command surface, so the socket must now stay
  ;; quiet — asserted here rather than only at the dispatch level, because the
  ;; regression that matters is a stray frame reaching a real client.
  (it "command-client-unknown-command-notifies-and-sends-no-reply"
    (with-isolated-hooks
      (with-fake-session (s)
        (with-test-listener (listener path (%test-socket-path "reply") :backlog 4)
          (let* ((client      (nerimux/net:connect-to path))
                 (server-sock (nerimux/net:accept-connection listener))
                 (nerimux::*clients* nil))
            (when server-sock
              (let ((conn    (nerimux::%add-client server-sock))
                    (payload (nerimux/protocol::encode-command-payload
                              :display-message :args '("hello"))))
                (expect (null (nerimux::%handle-multi-client-message
                               nerimux::+msg-command+ payload s conn)))
                ;; %client-notify pushes the bare text, not a (timestamp . text)
                ;; cons, so the log entry is the message itself.
                (let ((entry (first (nerimux::client-conn-message-log conn))))
                  (expect (stringp entry))
                  (expect (search "unknown command" entry) :to-be-truthy)
                  (expect (search "display-message" entry) :to-be-truthy))
                ;; Nothing should be readable on the client socket.  A short
                ;; timeout is enough: the reply, when it existed, was written
                ;; synchronously during the dispatch call above.
                (expect (null (nerimux/pty:select-fds
                               (list (nerimux/net:socket-fd client)) 200000))))))))))

  ;; run-command-client forwards a command to the server as a decodable
  ;; +msg-command+ frame (the `nerimux <command>` CLI path).  A -t target rides
  ;; along in the args for the server to parse.
  (it "command-client-sends-decodable-command-frame"
    (let ((name (format nil "cmdtest-~D" (get-universal-time)))
          (nerimux::*socket-path-override* (%test-socket-path "cmdtest")))
      (with-test-listener (listener path (nerimux::socket-path name) :backlog 4)
        (nerimux::run-command-client name '("next-window" "-t" "2"))
        (let ((server-sock (nerimux/net:accept-connection listener)))
          (expect server-sock :to-be-truthy)
          (when server-sock
            (let ((ready (nerimux/pty:select-fds
                          (list (nerimux/net:socket-fd server-sock)) 1000000)))
              (expect ready :to-be-truthy)
              (when ready
                (multiple-value-bind (type payload)
                    (nerimux::read-frame (nerimux/net:socket-stream server-sock))
                  (expect (eql nerimux::+msg-command+ type))
                  (multiple-value-bind (cmd target args)
                      (nerimux::decode-command-payload payload)
                    (declare (ignore target))
                    (expect (eq :next-window cmd))
                    (expect (equal '("-t" "2") args)))))))))))

  ;; run-command-client sends stdin after the split-window -I command frame.
  (it "command-client-split-window-I-forwards-stdin-frame"
    (let ((name (format nil "cmdinput-~D" (get-universal-time)))
          (nerimux::*socket-path-override* (%test-socket-path "cmdinput")))
      (with-test-listener (listener path (nerimux::socket-path name) :backlog 4)
        (with-input-from-string (*standard-input* "client stdin")
          (nerimux::run-command-client name '("split-window" "-I")))
        (let ((server-sock (nerimux/net:accept-connection listener)))
          (expect server-sock :to-be-truthy)
          (when server-sock
            (let ((ready (nerimux/pty:select-fds
                          (list (nerimux/net:socket-fd server-sock)) 1000000)))
              (expect ready :to-be-truthy)
              (when ready
                (multiple-value-bind (type payload)
                    (nerimux::read-frame (nerimux/net:socket-stream server-sock))
                  (expect (eql nerimux::+msg-command+ type))
                  (multiple-value-bind (cmd target args)
                      (nerimux::decode-command-payload payload)
                    (declare (ignore target))
                    (expect (eq :split-window cmd))
                    (expect (equal '("-I") args))))))
            (let ((ready (nerimux/pty:select-fds
                          (list (nerimux/net:socket-fd server-sock)) 1000000)))
              (expect ready :to-be-truthy)
              (when ready
                (multiple-value-bind (type payload)
                    (nerimux::read-frame (nerimux/net:socket-stream server-sock))
                  (expect (eql nerimux::+msg-key+ type))
                  (expect (string= "client stdin" (nerimux::decode-text payload)))))))))))

  ;;; -- exit-unattached: terminate when the last client detaches ----------------

  ;; %exit-after-last-detach-p is true only when NO clients remain AND exit-unattached
  ;; is on; default (off) keeps the session alive across detaches.
  (it "exit-after-last-detach-respects-option"
    (with-fresh-options
      (let ((nerimux::*clients* nil))
        (nerimux/options:set-option "exit-unattached" t)
        (expect (nerimux::%exit-after-last-detach-p) :to-be-truthy))
      (let ((nerimux::*clients* nil))
        (nerimux/options:set-option "exit-unattached" nil)
        (expect (nerimux::%exit-after-last-detach-p) :to-be-falsy))
      (let ((nerimux::*clients* (list (nerimux::%make-client-conn))))
        (nerimux/options:set-option "exit-unattached" t)
        (expect (nerimux::%exit-after-last-detach-p) :to-be-falsy))))

  ;; %exit-when-empty-p is true only when NO sessions remain AND exit-empty is on
  ;; (default); off keeps the server alive with zero sessions.
  (it "exit-when-empty-respects-option"
    (with-fresh-options
      (let ((nerimux::*server-sessions* nil))
        (nerimux/options:set-option "exit-empty" t)
        (expect (nerimux::%exit-when-empty-p) :to-be-truthy))
      (let ((nerimux::*server-sessions* nil))
        (nerimux/options:set-option "exit-empty" nil)
        (expect (nerimux::%exit-when-empty-p) :to-be-falsy))
      (let ((nerimux::*server-sessions* (list (cons "0" (make-fake-session)))))
        (nerimux/options:set-option "exit-empty" t)
        (expect (nerimux::%exit-when-empty-p) :to-be-falsy))))

  ;;; -- Integration: a broadcast frame reaches every attached client ------------

  ;; Two clients attached to the server both receive a broadcast frame — the core
  ;; multi-client property (one render fanned out to all).
  (it "multi-broadcast-reaches-all-clients"
    (with-isolated-hooks
      (with-fake-session (s)
        (with-test-listener (listener path (%test-socket-path "mtest") :backlog 4)
          (let* ((client1 (nerimux/net:connect-to path))
                 (server1 (nerimux/net:accept-connection listener))
                 (client2 (nerimux/net:connect-to path))
                 (server2 (nerimux/net:accept-connection listener))
                 (nerimux::*clients* nil))
            (when (and server1 server2)
              (nerimux::%add-client server1)
              (nerimux::%add-client server2)
              (setf nerimux::*dirty* t)
              (nerimux::%broadcast-frame s)
              ;; Both client sockets must now have a frame to read.  Gate the
              ;; reads on select so a missing frame fails fast (not hangs).
              (dolist (client (list client1 client2))
                (let ((ready (nerimux/pty:select-fds
                              (list (nerimux/net:socket-fd client)) 1000000)))
                  (expect ready :to-be-truthy)
                  (when ready
                    (multiple-value-bind (type payload)
                        (nerimux::read-frame (nerimux/net:socket-stream client))
                      (declare (ignore payload))
                      (expect (eql nerimux::+msg-frame+ type)))))))))))))

  (it "multi-broadcast-renders-private-client-surfaces"
    (with-isolated-hooks
      (with-fake-session (s :npanes 2)
        (let* ((window (session-active-window s))
               (panes (window-panes window))
               (pane1 (first panes))
               (pane2 (second panes)))
          (with-test-listener (listener path (%test-socket-path "mprivate") :backlog 4)
            (let* ((client1 (nerimux/net:connect-to path))
                   (server1 (nerimux/net:accept-connection listener))
                   (client2 (nerimux/net:connect-to path))
                   (server2 (nerimux/net:accept-connection listener))
                   (nerimux::*clients* nil)
                   (nerimux::*workspace-catalog-refresh-started-p* t)
                   (conn1 nil)
                   (conn2 nil))
              (unwind-protect
                   (when (and client1 client2 server1 server2 pane1 pane2)
                     (setf conn1 (nerimux::%add-client server1)
                           conn2 (nerimux::%add-client server2))
                     (setf (nerimux::client-conn-view conn1) :detail
                           (nerimux::client-conn-focus conn1) pane1
                           (nerimux::client-conn-rows conn1) 24
                           (nerimux::client-conn-cols conn1) 80
                           (nerimux::client-conn-view conn2) :detail
                           (nerimux::client-conn-focus conn2) pane2
                           (nerimux::client-conn-rows conn2) 12
                           (nerimux::client-conn-cols conn2) 40)
                     (pane-feed pane1
                                (cl-codec-kit:string-to-octets
                                 "client-one" :encoding :utf-8))
                     (pane-feed pane2
                                (cl-codec-kit:string-to-octets
                                 "client-two" :encoding :utf-8))
                     (setf nerimux::*dirty* t)
                     (nerimux::%broadcast-frame s)
                     (flet ((read-frame-text (client)
                              (let ((ready (nerimux/pty:select-fds
                                            (list (nerimux/net:socket-fd client))
                                            1000000)))
                                (expect ready :to-be-truthy)
                                (when ready
                                  (multiple-value-bind (type payload)
                                      (nerimux::read-frame
                                       (nerimux/net:socket-stream client))
                                    (expect (eql nerimux::+msg-frame+ type))
                                    (decode-text payload))))))
                       (let ((frame1 (read-frame-text client1))
                             (frame2 (read-frame-text client2)))
                         (expect (and frame1 (plusp (length frame1)))
                                 :to-be-truthy)
                         (expect (and frame2 (plusp (length frame2)))
                                 :to-be-truthy)
                         (expect (and frame1 frame2 (not (string= frame1 frame2)))
                                 :to-be-truthy))))
                (dolist (conn (remove nil (list conn1 conn2)))
                  (when (member conn nerimux::*clients*)
                    (nerimux::%drop-client conn)))
                (dolist (socket (remove nil (list client1 client2 server1 server2)))
                  (ignore-errors (nerimux/net:close-socket socket))))))))))

  (it "multi-socket-c-q-d-detaches-with-session-resident"
    (with-isolated-hooks
      (with-fake-session (s)
        (let* ((window (session-active-window s))
               (pane (window-active-pane window))
               (nerimux::*clients* nil)
               (nerimux::*workspace-catalog-refresh-started-p* t))
          (with-test-listener (listener path (%test-socket-path "mdetach") :backlog 4)
            (let* ((client1 (nerimux/net:connect-to path))
                   (server1 (nerimux/net:accept-connection listener))
                   (client2 nil)
                   (server2 nil)
                   (conn1 nil)
                   (conn2 nil))
              (flet ((send-and-dispatch (client conn frame)
                       (send-frame (nerimux/net:socket-stream client) frame)
                       (let ((ready (nerimux/pty:select-fds
                                     (list (nerimux::client-conn-fd conn))
                                     1000000)))
                         (expect ready :to-be-truthy)
                         (when ready
                           (nerimux::%read-and-dispatch-client-message s conn)))))
                (unwind-protect
                     (when (and client1 server1 pane)
                       (setf conn1 (nerimux::%add-client server1))
                       (expect (null (send-and-dispatch
                                      client1 conn1 (msg-attach 24 80)))
                               :to-be-truthy)
                       (expect (null (send-and-dispatch
                                      client1 conn1 (msg-key (vector #x11))))
                               :to-be-truthy)
                       (expect (eq :drop
                                   (send-and-dispatch
                                    client1 conn1
                                    (msg-key (vector (char-code #\d)))))
                               :to-be-truthy)
                       (nerimux::%apply-client-disposition :drop conn1)
                       (expect (null nerimux::*clients*) :to-be-truthy)
                       (expect (eq pane (window-active-pane window))
                               :to-be-truthy)
                       (setf client2 (nerimux/net:connect-to path)
                             server2 (nerimux/net:accept-connection listener))
                       (expect client2 :to-be-truthy)
                       (expect server2 :to-be-truthy)
                       (when (and client2 server2)
                         (setf conn2 (nerimux::%add-client server2))
                         (expect (null (send-and-dispatch
                                        client2 conn2 (msg-attach 24 80)))
                                 :to-be-truthy)
                         (expect (member conn2 nerimux::*clients*)
                                 :to-be-truthy)))
                  (dolist (conn (remove nil (list conn1 conn2)))
                    (when (member conn nerimux::*clients*)
                      (nerimux::%drop-client conn)))
                  (dolist (socket
                            (remove nil (list client1 client2 server1 server2)))
                    (ignore-errors (nerimux/net:close-socket socket)))))))))))

  (it "multi-socket-renders-live-pty-output"
    (with-pty-available
      (with-session (s 8 40)
        (with-loop-state
          (let* ((window (session-active-window s))
                 (pane (window-active-pane window))
                 (marker "nerimux-live-pty-marker")
                 (nerimux::*clients* nil)
                 (nerimux::*workspace-catalog-refresh-started-p* t))
            (with-test-listener (listener path (%test-socket-path "mpty")
                                           :backlog 2)
              (let* ((client (nerimux/net:connect-to path))
                     (server (nerimux/net:accept-connection listener))
                     (conn nil))
                (flet ((screen-text (screen-pane)
                         (let ((screen (pane-screen screen-pane)))
                           (cl-concurrent-kit:with-lock-held
                               ((nerimux/terminal:screen-lock screen))
                             (with-output-to-string (output)
                               (dotimes (y (screen-height screen))
                                 (dotimes (x (screen-width screen))
                                   (write-char
                                    (cell-char (screen-cell screen x y))
                                    output)))))))
                       (send-and-dispatch (frame)
                         (send-frame (nerimux/net:socket-stream client) frame)
                         (let ((ready (select-fds
                                       (list (nerimux::client-conn-fd conn))
                                       1000000)))
                           (expect ready :to-be-truthy)
                           (when ready
                             (nerimux::%read-and-dispatch-client-message s conn)))))
                  (unwind-protect
                       (when (and client server pane)
                         (setf conn (nerimux::%add-client server))
                         (expect (null (send-and-dispatch (msg-attach 8 40)))
                                 :to-be-truthy)
                         (setf (nerimux::client-conn-view conn) :detail
                               (nerimux::client-conn-focus conn) pane)
                         (nerimux::start-reader-thread pane)
                         (pty-write (pane-fd pane)
                                    (format nil "printf '%s\\n' ~A~%" marker))
                         (loop repeat 100
                               until (search marker (screen-text pane))
                               do (sleep 0.05))
                         (expect (search marker (screen-text pane))
                                 :to-be-truthy)
                         (setf nerimux::*dirty* t)
                         (nerimux::%broadcast-frame s)
                         (let ((ready (select-fds
                                       (list (nerimux/net:socket-fd client))
                                       1000000)))
                           (expect ready :to-be-truthy)
                           (when ready
                             (multiple-value-bind (type payload)
                                 (nerimux::read-frame
                                  (nerimux/net:socket-stream client))
                               (expect (eql nerimux::+msg-frame+ type))
                               (expect (search marker
                                               (decode-text payload))
                                       :to-be-truthy)))))
                    (when (and conn (member conn nerimux::*clients*))
                      (nerimux::%drop-client conn))
                    (dolist (socket (remove nil (list client server)))
                      (ignore-errors (nerimux/net:close-socket socket))))))))))))

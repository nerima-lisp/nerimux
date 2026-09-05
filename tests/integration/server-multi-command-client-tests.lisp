(in-package #:nerimux/test)

(describe "server-multi-suite"


  (it "command-client-unknown-command-notifies-and-sends-no-reply"
    (progn
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
                (let ((entry (first (nerimux::client-conn-message-log conn))))
                  (expect (stringp entry))
                  (expect (search "unknown command" entry) :to-be-truthy)
                  (expect (search "display-message" entry) :to-be-truthy))
                (expect (null (nerimux/pty:select-fds
                               (list (nerimux/net:socket-fd client)) 200000))))))))))

  (it "command-client-sends-decodable-command-frame"
    (with-test-listener (listener path (%test-socket-path "cmdtest") :backlog 4)
      (let ((client (nerimux/net:connect-to path)))
        (expect client :to-be-truthy)
        (when client
          (send-frame (nerimux/net:socket-stream client)
                      (nerimux::msg-command "next-window" nil '("-t" "2")))
          (force-output (nerimux/net:socket-stream client))
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
                      (expect (equal '("-t" "2") args))))))))))))


  (it "last-client-detach-leaves-running-true"
    (let* ((conn (nerimux::%make-client-conn))
           (nerimux::*clients* (list conn))
           (nerimux::*running* t))
      (expect (null (nerimux::%apply-client-disposition :drop conn)))
      (expect (null nerimux::*clients*))
      (expect nerimux::*running* :to-be-truthy)))

  (it "quit-disposition-is-returned-to-the-server-loop"
    (let ((conn (nerimux::%make-client-conn)))
      (expect (eql :quit (nerimux::%apply-client-disposition :quit conn)))))


  (it "multi-broadcast-reaches-all-clients"
    (progn
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
              (dolist (client (list client1 client2))
                (let ((ready (nerimux/pty:select-fds
                              (list (nerimux/net:socket-fd client)) 1000000)))
                  (expect ready :to-be-truthy)
                  (when ready
                    (multiple-value-bind (type payload)
                        (nerimux::read-frame (nerimux/net:socket-stream client))
                      (declare (ignore payload))
                      (expect (eql nerimux::+msg-frame+ type))))))))))))

  (it "multi-broadcast-renders-private-client-surfaces"
    (progn
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
                     (setf (nerimux::client-conn-view conn1) :pane
                           (nerimux::client-conn-focus conn1) pane1
                           (nerimux::client-conn-rows conn1) 24
                           (nerimux::client-conn-cols conn1) 80
                           (nerimux::client-conn-view conn2) :pane
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
    (progn
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
                    (ignore-errors (nerimux/net:close-socket socket))))))))))))

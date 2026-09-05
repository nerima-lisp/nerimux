(in-package #:nerimux/pty-test)

(describe "server-multi-suite"
          (it "multi-socket-renders-live-pty-output"
              (with-pty-available
               (with-session (s 10 40)
                             (let* ((window (session-active-window s))
                                    (pane (window-active-pane window))
                                    (marker "nerimux-live-pty-marker")
                                    (nerimux::*clients* nil)
                                    (nerimux::*workspace-catalog-refresh-started-p*
                                     t))
                               (with-test-listener
                                (listener path
                                          (%test-socket-path "mpty")
                                          :backlog
                                          2)
                                (let* ((client (nerimux/net:connect-to path))
                                       (server
                                        (nerimux/net:accept-connection listener))
                                       (conn nil))
                                  (flet ((screen-text (screen-pane)
                                           (let ((screen
                                                  (pane-screen screen-pane)))
                                             (cl-concurrent-kit:with-lock-held
                                              ((nerimux/terminal:screen-lock
                                                screen))
                                              (with-output-to-string (output)
                                                (dotimes 
                                                    (y (screen-height screen))
                                                  (dotimes 
                                                      (x (screen-width screen))
                                                    (write-char
                                                     (cell-char
                                                      (screen-cell screen x y))
                                                     output)))))))
                                         (send-and-dispatch (frame)
                                           (send-frame
                                            (nerimux/net:socket-stream client)
                                            frame)
                                           (let ((ready
                                                  (select-fds
                                                   (list
                                                    (nerimux::client-conn-fd
                                                     conn))
                                                   1000000)))
                                             (expect ready :to-be-truthy)
                                             (when ready
                                               (nerimux::%read-and-dispatch-client-message
                                                s
                                                conn)))))
                                    (unwind-protect 
                                        (when (and client server pane)
                                          (setf conn (nerimux::%add-client
                                                      server))
                                          (expect
                                           (null
                                            (send-and-dispatch
                                             (msg-attach 10 40)))
                                           :to-be-truthy)
                                          (setf (nerimux::client-conn-view conn) :detail
                                                (nerimux::client-conn-focus
                                                 conn) pane)
                                          (nerimux::start-reader-thread pane)
                                          (pty-write (pane-fd pane)
                                                     (format nil
                                                             "printf '%s\\n' ~A~%"
                                                             marker))
                                          (let ((marker-seen-p
                                                 (let ((deadline
                                                        (+
                                                         (get-internal-real-time)
                                                         (* 5
                                                            internal-time-units-per-second))))
                                                   (loop when (search marker
                                                                      (screen-text
                                                                       pane))
                                                           return t
                                                         when (>=
                                                               (get-internal-real-time)
                                                               deadline)
                                                           return nil
                                                         do (sb-thread:thread-yield)))))
                                            (expect marker-seen-p :to-be-truthy))
                                          (setf nerimux::*dirty* t)
                                          (nerimux::%broadcast-frame s)
                                          (let ((ready
                                                 (select-fds
                                                  (list
                                                   (nerimux/net:socket-fd
                                                    client))
                                                  1000000)))
                                            (expect ready :to-be-truthy)
                                            (when ready
                                              (multiple-value-bind (type
                                                                    payload) 
                                                  (nerimux::read-frame
                                                   (nerimux/net:socket-stream
                                                    client))
                                                (expect
                                                 (eql nerimux::+msg-frame+ type))
                                                (expect
                                                 (search marker
                                                         (decode-text payload))
                                                 :to-be-truthy)))))
                                      (when 
                                          (and conn
                                               (member conn nerimux::*clients*))
                                        (nerimux::%drop-client conn))
                                      (dolist 
                                          (socket
                                           (remove nil (list client server)))
                                        (ignore-errors
                                         (nerimux/net:close-socket socket))))))))))))

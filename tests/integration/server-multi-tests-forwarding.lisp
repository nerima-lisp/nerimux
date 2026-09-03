(in-package #:nerimux/test)

(describe "server-multi-suite"


  (it "multi-handle-unknown-command-notifies-without-quit-or-drop"
    (with-fake-session (s :nwindows 2)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (before (session-active-window s))
             (payload (nerimux/protocol::encode-command-payload :next-window)))
        (expect (null (nerimux::%handle-multi-client-message
                       nerimux::+msg-command+ payload s conn)))
        (expect (eq before (session-active-window s)))
        (expect (member conn nerimux::*clients* :test #'eq))
        (expect (search "unknown command"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "multi-drop-client-removes-from-registry"
    (progn
      (let* ((a (%make-test-conn))
             (b (%make-test-conn))
             (nerimux::*clients* (list a b)))
        (nerimux::%drop-client a)
        (expect (equal (list b) nerimux::*clients*))
        (nerimux::%drop-client a)
        (expect (equal (list b) nerimux::*clients*)))))

  (it "multi-drop-client-does-not-signal-when-close-socket-fails"
    (let* ((conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (setf (nerimux::client-conn-socket conn) :fake-socket)
      (with-stubbed-fdefinition
          ((nerimux/net:close-socket
            (lambda (&rest args)
              (declare (ignore args))
              (error "peer gone"))))
        (finishes (nerimux::%drop-client conn)
                  "%drop-client must not signal when close-socket fails"))
      (expect (null nerimux::*clients*))))

  (it "multi-drop-client-swallow-bye-transport-failures"
    (dolist (condition-type '(sb-ext:timeout
                              sb-bsd-sockets:socket-error
                              stream-error))
      (let* ((stream (make-two-way-stream
                      (make-string-input-stream "")
                      (make-string-output-stream)))
             (conn (let ((value (%make-test-conn)))
                     (setf (nerimux::client-conn-stream value) stream)
                     value))
             (nerimux::*clients* (list conn)))
        (with-stubbed-fdefinition
            ((nerimux/transport:send-frame
              (lambda (&rest args)
                (declare (ignore args))
                (case condition-type
                  (stream-error (error 'stream-error :stream stream))
                  (sb-bsd-sockets:socket-error
                   (error 'sb-bsd-sockets:socket-error
                          :syscall "send" :errno 32))
                  (t (error 'sb-ext:timeout))))))
          (finishes (nerimux::%drop-client conn :bye t)
                    "drop must contain ~A while sending bye"
                    condition-type))
        (expect (null nerimux::*clients*)))))


  (it "multi-accept-pending-connection-survives-accept-connection-failure"
    (let ((nerimux::*clients* nil))
      (with-stubbed-fdefinition
          ((nerimux/net:accept-connection
            (lambda (&rest args)
              (declare (ignore args))
              (error "EMFILE"))))
        (finishes
         (nerimux::%accept-pending-connection :fake-listener 5 (list 5))
         "%accept-pending-connection must not signal when accept-connection fails"))
      (expect (null nerimux::*clients*))))

  (it "multi-accept-pending-connection-ignores-a-missing-peer"
    (let ((nerimux::*clients* nil))
      (with-stubbed-fdefinition
          ((nerimux/net:accept-connection
            (lambda (&rest args)
              (declare (ignore args))
              nil)))
        (finishes
         (nerimux::%accept-pending-connection :fake-listener 5 (list 5))))
      (expect (null nerimux::*clients*))))

  (it "multi-apply-client-disposition-ignores-unknown-disposition"
    (let* ((conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (expect (null (nerimux::%apply-client-disposition :unknown conn)))
      (expect (equal (list conn) nerimux::*clients*))))


  (it "multi-add-client-refuses-at-max-clients-cap"
    (let* ((full (loop repeat nerimux::+max-clients+ collect (%make-test-conn)))
           (nerimux::*clients* full)
           (close-call-count 0))
      (with-stubbed-fdefinition
          ((nerimux/net:close-socket
            (lambda (&rest args)
              (declare (ignore args))
              (incf close-call-count)
              nil)))
        (expect (null (nerimux::%add-client :fake-socket))))
      (expect (= nerimux::+max-clients+ (length nerimux::*clients*)))
      (expect (eq full nerimux::*clients*))
      (expect (= 1 close-call-count))))


  (it "multi-serve-iteration-closes-the-fd-of-a-client-that-attaches-then-closes-without-reading"
    (with-client-fd-reclamation (s "leak-attach-noread")
      (send-frame (socket-stream client) (msg-attach 24 80))
      (close-socket client)))

  (it "multi-serve-iteration-closes-the-fd-of-a-client-that-closes-without-sending-or-reading"
    (with-client-fd-reclamation (s "leak-bare-noread")
      (close-socket client))))

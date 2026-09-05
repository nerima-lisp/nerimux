(in-package #:nerimux/test)

(describe "net-malformed-utf8-dispatch-suite"

  (it "dispatch-ready-clients-drops-only-the-sender-of-a-malformed-command-frame"
    (progn
      (with-fake-session (s)
        (with-test-listener (listener path (%test-socket-path "malformed-utf8")
                                      :backlog 4)
          (let ((attacker  (nerimux/net:connect-to path))
                (bystander nil))
            (unwind-protect
                 (let* ((attacker-sock  (nerimux/net:accept-connection listener))
                        (ignored        (setf bystander (nerimux/net:connect-to path)))
                        (bystander-sock (nerimux/net:accept-connection listener))
                        (nerimux::*clients* nil))
                   (declare (ignore ignored))
                   (expect attacker-sock :to-be-truthy)
                   (expect bystander-sock :to-be-truthy)
                   (let ((bad-conn  (nerimux::%add-client attacker-sock))
                         (good-conn (nerimux::%add-client bystander-sock))
                         (payload   (make-array 2 :element-type '(unsigned-byte 8)
                                                  :initial-contents '(#xFF #x00)))
                         (result    :never-ran))
                     (send-frame (nerimux/net:socket-stream attacker)
                                 (encode-frame +msg-command+ payload))
                     (finishes
                       (setf result
                             (nerimux::%dispatch-ready-clients
                              s (list (nerimux::client-conn-fd bad-conn)))))
                     (expect (not (eq :quit result)))
                     (expect (equal (list good-conn) nerimux::*clients*))))
              (ignore-errors (nerimux/net:close-socket attacker))
              (when bystander
                (ignore-errors (nerimux/net:close-socket bystander))))))))))

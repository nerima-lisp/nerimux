(in-package #:nerimux/test)

(describe "server-multi-forwarding-suite"

  (it "forwarded-command-message-keeps-ui-and-rejects-unknown-commands"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload :home))))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload :not-a-ui-command))))
        (let ((nerimux::*dirty* nil))
          (expect (null
                   (nerimux::%handle-multi-command-message
                    s conn nil)))
          (expect nerimux::*dirty*)))))

  (it "forwarded-command-message-applies-focus-and-viewport"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload
                   :viewport :args '("4")))))
        (expect (= 4 (nerimux::client-conn-viewport conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload
                   :focus))))
        (expect (eq (nerimux::window-active-pane
                     (nerimux::session-active-window s))
                    (nerimux::client-conn-focus conn))))))
  )

(in-package #:nerimux/pty-test)

(describe "server-suite"

  (it "new-session-command"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-empty-registry
      (let ((nerimux/session::*session-id-counter* 0))
        (with-session (sess 24 80)
          (setf (nerimux::session-name sess) "testsess")
          (nerimux::server-add-session sess)
          (expect sess :to-be-truthy)
          (expect (= 1 (length nerimux::*server-sessions*)))
          (let ((found (nerimux::server-find-session "testsess")))
            (expect (eq sess found))))))))

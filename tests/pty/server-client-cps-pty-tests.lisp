(in-package #:nerimux/pty-test)

(describe "server-suite"

  (it "run-server-session-registry-initialization"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-empty-registry
      (let ((nerimux/session::*session-id-counter* 0))
        (setf nerimux::*server-sessions* nil)
        (let ((session (create-initial-session 24 80)))
          (nerimux::server-add-session session)
          (expect (= 1 (length nerimux::*server-sessions*)))
          (expect (nerimux::server-find-session (session-name session)) :to-be-truthy)
          (dolist (pane (all-panes session))
            (ignore-errors (pty-close (pane-fd pane) (pane-pid pane)))))))))

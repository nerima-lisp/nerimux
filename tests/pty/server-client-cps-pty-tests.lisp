(in-package #:nerimux/pty-test)

;;;; run-server's session-registry initialization: a real PTY-backed spawn.
;;;;
;;;; Moved from tests/unit/bootstrap/server-client-cps-tests.lisp (R9.2): the one
;;;; case there that spawns a real PTY, via create-initial-session.  The
;;;; define-message-dispatch-fn macro-engine cases in that file spawn nothing
;;;; and stayed in nerimux/test.
(describe "server-suite"

  ;; The session-registry setup that run-server performs: reset to NIL then add the initial session.
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

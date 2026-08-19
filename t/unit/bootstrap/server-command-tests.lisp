(in-package #:nerimux/test)

;;;; Server command helpers.

(describe "server-suite"

  ;; Creating a session (create-initial-session, the surviving primitive behind
  ;; the deleted new-session tmux command), naming it, and registering it via
  ;; server-add-session makes it findable in the server registry.
  (it "new-session-command"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-empty-registry
      (let ((nerimux/model::*session-id-counter* 0))
        (with-session (sess 24 80)
          (setf (nerimux::session-name sess) "testsess")
          (nerimux::server-add-session sess)
          (expect sess :to-be-truthy)
          (expect (= 1 (length nerimux::*server-sessions*)))
          (let ((found (nerimux::server-find-session "testsess")))
            (expect (eq sess found)))))))

  ;; After killing a session it is removed from the server registry.
  (it "kill-session-command"
    (with-empty-registry
      (let ((s1 (make-session :id 1 :name "alive"  :windows nil))
            (s2 (make-session :id 2 :name "doomed" :windows nil)))
        (nerimux::server-add-session s1)
        (nerimux::server-add-session s2)
        (nerimux::server-remove-session "doomed")
        (expect (= 1 (length (nerimux::server-all-sessions))))
        (expect (null (nerimux::server-find-session "doomed")))))))

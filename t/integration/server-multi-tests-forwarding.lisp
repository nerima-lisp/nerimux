(in-package #:nerimux/test)

;;;; Command dispatch and client-output tests for the multi-client server.

(describe "server-multi-suite"

  ;;; ── Command dispatch ──────────────────────────────────────────────────────

  ;; Any command the workspace UI does not recognize -- e.g. a bare tmux CLI
  ;; command like `next-window` -- is no longer run against the tmux command
  ;; table server-side (that command-forwarding path, %dispatch-forwarded-command
  ;; et al, was removed).  It now produces a client notification and the
  ;; dispatch returns NIL: the loop keeps running and CONN is neither quit nor
  ;; dropped.
  (it "multi-handle-unknown-command-notifies-without-quit-or-drop"
    (with-fake-session (s :nwindows 2)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (before (session-active-window s))
             (payload (nerimux/protocol::encode-command-payload :next-window)))
        (expect (null (nerimux::%handle-multi-client-message
                       nerimux::+msg-command+ payload s conn)))
        ;; The command did not run server-side: the active window is unchanged
        ;; (next-window would have advanced it, as in the deleted
        ;; multi-handle-forwarded-command-runs-server-side test).
        (expect (eq before (session-active-window s)))
        ;; CONN is still attached and was notified instead of the command running.
        (expect (member conn nerimux::*clients* :test #'eq))
        (expect (search "unknown command"
                        (first (nerimux::client-conn-message-log conn)))))))

  ;; %drop-client (no bye, no socket) removes the conn from *clients*.
  (it "multi-drop-client-removes-from-registry"
    (with-isolated-hooks
      (let* ((a (%make-test-conn))
             (b (%make-test-conn))
             (nerimux::*clients* (list a b)))
        (nerimux::%drop-client a)
        (expect (equal (list b) nerimux::*clients*))
        ;; Idempotent: dropping again is a no-op.
        (nerimux::%drop-client a)
        (expect (equal (list b) nerimux::*clients*))))))

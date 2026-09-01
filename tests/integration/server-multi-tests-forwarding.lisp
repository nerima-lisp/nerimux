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
    (progn
      (let* ((a (%make-test-conn))
             (b (%make-test-conn))
             (nerimux::*clients* (list a b)))
        (nerimux::%drop-client a)
        (expect (equal (list b) nerimux::*clients*))
        ;; Idempotent: dropping again is a no-op.
        (nerimux::%drop-client a)
        (expect (equal (list b) nerimux::*clients*)))))

  ;; %drop-client MUST NOT SIGNAL (its own docstring's contract): it runs as
  ;; WITH-LOOP-SAFE-ERROR's on-error handler and in %RUN-MULTI-SERVER-LOOP's
  ;; unwind cleanup, both without any guard above them.  A dead peer's socket
  ;; failing to close (e.g. a second BROKEN-PIPE on the retry flush) must not
  ;; propagate out of here, and CONN must still come off the registry.
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

  ;;; ── Accept-loop resilience ───────────────────────────────────────────────

  ;; %accept-pending-connection must not let a failure from accept-connection
  ;; itself (e.g. EMFILE fd exhaustion) escape into the serve loop and kill
  ;; the whole server (CWE-703): the failed accept is dropped, and nothing is
  ;; registered, but already-attached clients keep being served.
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

  ;; A readiness notification can race with a peer disappearing before accept.
  ;; NIL is a normal no-registration result, not a server-loop failure.
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

  ;; Dispositions produced by an extension or malformed dispatch result are
  ;; deliberately ignored: only the three protocol lifecycle dispositions
  ;; above have side effects on the connection registry.
  (it "multi-apply-client-disposition-ignores-unknown-disposition"
    (let* ((conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (expect (null (nerimux::%apply-client-disposition :unknown conn)))
      (expect (equal (list conn) nerimux::*clients*))))

  ;;; ── Connection cap ───────────────────────────────────────────────────────

  ;; %add-client refuses a new connection once *clients* already holds
  ;; +max-clients+ entries (refuse-newest, not evict-eldest): it closes the
  ;; incoming socket instead of registering it, and the registry is left
  ;; untouched.
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

  ;;; ── Connection leak: client closes without ever reading a frame back ─────
  ;;;
  ;;; %stale-socket-p's liveness probe (main-startup-socket.lisp:28-43) connects
  ;;; to a live server then closes immediately, never reading anything back --
  ;;; the same shape as a real client that sends its attach frame and vanishes
  ;;; before the first render reaches it.  Both must still be reclaimed by the
  ;;; ordinary %multi-serve-iteration event-loop path (the real select-fds +
  ;;; broadcast/read-frame + %apply-client-disposition pipeline), not just by
  ;;; the direct %dispatch-ready-clients call the sibling test in
  ;;; server-multi-tests-loop.lisp already covers.
  ;;;
  ;;; Checking (null *clients*) alone is NOT a sufficient oracle here: the
  ;;; confirmed defect left *clients* bookkeeping perfectly clean while the
  ;;; underlying socket stream stayed open.  The support macro therefore
  ;;; retains the connection object and checks that its stream is closed.

  (it "multi-serve-iteration-closes-the-fd-of-a-client-that-attaches-then-closes-without-reading"
    (with-client-fd-reclamation (s "leak-attach-noread")
      (send-frame (socket-stream client) (msg-attach 24 80))
      (close-socket client)))

  ;; Bare variant: the client sends NOTHING at all before closing -- exactly
  ;; %stale-socket-p's own probe shape (connect, close, never send, never
  ;; read).  This is the case that leaks on every `nerimux attach` to a live
  ;; server.
  (it "multi-serve-iteration-closes-the-fd-of-a-client-that-closes-without-sending-or-reading"
    (with-client-fd-reclamation (s "leak-bare-noread")
      (close-socket client))))

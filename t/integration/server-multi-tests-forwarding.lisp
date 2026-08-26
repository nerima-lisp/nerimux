(in-package #:nerimux/test)

;;;; Command dispatch and client-output tests for the multi-client server.

(defun %raw-fd-open-p (fd)
  "T when FD is still open at the OS level: attempts a raw close(2) on FD and
   reports whether that syscall itself succeeded (0, meaning FD was open) or
   failed because FD was already closed (-1, EBADF).

   Used by the connection-leak tests below, which cannot trust
   (null *clients*) alone: the confirmed defect left *clients* bookkeeping
   perfectly clean (the conn really was removed) while the underlying OS
   file descriptor stayed open forever, because closing a client whose
   broadcast write had already failed made CL:CLOSE's own flush-before-close
   retry hit a second BROKEN-PIPE and abort before ever reaching UNIX-CLOSE
   -- silently swallowed by %DROP-CLIENT's (necessarily broad)
   PEER-IO-FAILURE handler.  A second close(2) on an fd this test's own
   CLIENT socket still separately owns is harmless: CLIENT's own close will
   likewise just see EBADF and ignore it, same as any other double-close."
  (zerop (sb-alien:alien-funcall
          (sb-alien:extern-alien "close" (function sb-alien:int sb-alien:int))
          fd)))

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
  ;;; confirmed defect left *clients* bookkeeping perfectly clean (the conn
  ;;; really was removed) while the underlying OS file descriptor stayed open
  ;;; forever, because closing a client whose broadcast write had already
  ;;; failed made CL:CLOSE's own flush-before-close retry hit a second
  ;;; BROKEN-PIPE and abort before ever reaching UNIX-CLOSE -- silently
  ;;; swallowed by %DROP-CLIENT's (necessarily broad) PEER-IO-FAILURE handler.
  ;;; %RAW-FD-OPEN-P (defined above, outside this DESCRIBE) re-closes the raw
  ;;; descriptor directly to check what actually happened at the OS level,
  ;;; independent of *CLIENTS*.

  (it "multi-serve-iteration-closes-the-fd-of-a-client-that-attaches-then-closes-without-reading"
    (with-fake-session (s)
      (with-test-listener
          (listener path (%test-socket-path "leak-attach-noread") :backlog 4)
        (let* ((nerimux::*clients* nil)
               (client (connect-to path))
               (server-sock (accept-connection listener)))
          (unwind-protect
              (progn
                (expect server-sock :to-be-truthy)
                (let* ((conn   (nerimux::%add-client server-sock))
                       (raw-fd (nerimux::client-conn-fd conn)))
                  (send-frame (socket-stream client) (msg-attach 24 80))
                  (close-socket client)
                  (loop repeat 20
                        until (eq :quit (nerimux::%multi-serve-iteration listener s)))
                  (expect (null nerimux::*clients*))
                  (expect (null (%raw-fd-open-p raw-fd)))))
            (ignore-errors (close-socket client)))))))

  ;; Bare variant: the client sends NOTHING at all before closing -- exactly
  ;; %stale-socket-p's own probe shape (connect, close, never send, never
  ;; read).  This is the case that leaks on every `nerimux attach` to a live
  ;; server.
  (it "multi-serve-iteration-closes-the-fd-of-a-client-that-closes-without-sending-or-reading"
    (with-fake-session (s)
      (with-test-listener
          (listener path (%test-socket-path "leak-bare-noread") :backlog 4)
        (let* ((nerimux::*clients* nil)
               (client (connect-to path))
               (server-sock (accept-connection listener)))
          (unwind-protect
              (progn
                (expect server-sock :to-be-truthy)
                (let* ((conn   (nerimux::%add-client server-sock))
                       (raw-fd (nerimux::client-conn-fd conn)))
                  (close-socket client)
                  (loop repeat 20
                        until (eq :quit (nerimux::%multi-serve-iteration listener s)))
                  (expect (null nerimux::*clients*))
                  (expect (null (%raw-fd-open-p raw-fd)))))
            (ignore-errors (close-socket client))))))))

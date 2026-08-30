(in-package #:nerimux/test)

;;;; The end-to-end guard that makes strict UTF-8 decoding safe.
;;;;
;;;; Lives in tests/integration/ rather than with the rest of the malformed-UTF-8
;;;; cases in packages/net/tests/. Those exercise the codec; this one drives the
;;;; server event loop through nerimux::%dispatch-ready-clients and asserts on
;;;; nerimux::*clients*, so it spans nerimux-net and the bootstrap core and
;;;; belongs to neither unit alone.

(describe "net-malformed-utf8-dispatch-suite"

  ;; The end-to-end claim.  A same-uid peer sends a structurally VALID frame
  ;; whose payload is not UTF-8 — the cheapest possible attack on the socket.
  ;; The decode error must be absorbed by the event loop, cost exactly the one
  ;; client that sent it, and leave the session and every other client running.
  ;;
  ;; Only the offender's fd is placed in READY, so the quiet client is never read
  ;; from; its survival in *CLIENTS* is therefore a real isolation check and not
  ;; an artefact of the loop having skipped it.
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
                   ;; The fixture is ASSERTED, never branched on.  ACCEPT-CONNECTION
                   ;; returns NIL on timeout by design (net.lisp), so a (WHEN (AND
                   ;; attacker-sock bystander-sock) ...) here would skip every
                   ;; assertion below on a loaded machine and still report PASS —
                   ;; silently retiring the only test that pins strictness and the
                   ;; WITH-LOOP-SAFE-ERROR guard as a matched pair.
                   (expect attacker-sock :to-be-truthy)
                   (expect bystander-sock :to-be-truthy)
                   (let ((bad-conn  (nerimux::%add-client attacker-sock))
                         (good-conn (nerimux::%add-client bystander-sock))
                         (payload   (make-array 2 :element-type '(unsigned-byte 8)
                                                  :initial-contents '(#xFF #x00)))
                         (result    :never-ran))
                     (send-frame (nerimux/net:socket-stream attacker)
                                 (encode-frame +msg-command+ payload))
                     ;; The decode error must not escape the event loop.
                     (finishes
                       (setf result
                             (nerimux::%dispatch-ready-clients
                              s (list (nerimux::client-conn-fd bad-conn)))))
                     ;; It must not end the session either.
                     (expect (not (eq :quit result)))
                     ;; And it must cost exactly one client: the sender.
                     (expect (equal (list good-conn) nerimux::*clients*))))
              (ignore-errors (nerimux/net:close-socket attacker))
              (when bystander
                (ignore-errors (nerimux/net:close-socket bystander))))))))))

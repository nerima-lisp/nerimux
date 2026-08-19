(in-package #:nerimux/test)

;;;; Malformed UTF-8 on the +msg-command+ control channel.
;;;;
;;;; These tests pin a decision, not merely an observed behaviour, so the
;;;; assertions below are deliberately two-sided.
;;;;
;;;; nerimux decodes wire payloads under two OPPOSITE policies, chosen per
;;;; channel:
;;;;
;;;;   SPLIT-ON-NUL-BYTES (protocol-command.lisp) — STRICT.  Its fields are
;;;;   interned and executed as commands, so a repaired byte would be a guess
;;;;   with consequences: it could turn a malformed command into a different
;;;;   well-formed one, and it would let arbitrary non-UTF-8 input reach INTERN.
;;;;
;;;;   DECODE-TEXT (protocol.lisp) — LENIENT (U+FFFD).  Its payloads are display
;;;;   text that the client only writes to stdout, so a repaired byte costs one
;;;;   glyph, while signalling would unwind the client's unguarded event loop.
;;;;
;;;; Strictness on the command channel is safe ONLY because the condition has a
;;;; bounded per-client destination: the WITH-LOOP-SAFE-ERROR guard in
;;;; %READ-AND-DISPATCH-CLIENT-MESSAGE (server-multi-loop.lisp) converts it to
;;;; the :DROP disposition, disconnecting the sender alone.  Strictness and that
;;;; guard are a matched pair, and removing either one alone is a bug:
;;;;
;;;;   guard removed      → any same-uid process can kill the server, and with
;;;;                        it every session and every attached client;
;;;;   strictness removed → malformed bytes are silently repaired into some
;;;;                        other command.
;;;;
;;;; Both halves are therefore asserted together, in this one file, so that a
;;;; future change cannot quietly drop one and keep the other.
;;;;
;;;; The two byte patterns used throughout are the two distinct decode failures
;;;; a hostile or buggy peer can produce: #xFF, which is never a legal UTF-8
;;;; leading byte, and E3 81, the first two bytes of a three-byte sequence (the
;;;; U+3040 hiragana block) cut short by the field delimiter.

(describe "protocol-command-malformed-utf8-suite"

  ;;; ── Command channel: strict, does not repair ────────────────────────────────

  ;; A lone #xFF before the NUL terminator must be refused, not repaired.
  (it "split-on-nul-bytes-signals-on-invalid-leading-byte"
    (let ((payload (make-array 2 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#xFF #x00))))
      (signals cl-codec-kit:decode-error
        (nerimux/protocol:split-on-nul-bytes payload))))

  ;; A multi-byte sequence truncated by the field delimiter must be refused too:
  ;; the field boundary must not be mistaken for a decodable character.
  (it "split-on-nul-bytes-signals-on-truncated-sequence"
    (let ((payload (make-array 3 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#xE3 #x81 #x00))))
      (signals cl-codec-kit:decode-error
        (nerimux/protocol:split-on-nul-bytes payload))))

  ;; The full decoder inherits that strictness: a VALID command name ("ls")
  ;; followed by a malformed ARGUMENT field still refuses the whole payload.
  ;; Rejecting the frame rather than just the field is intended — running a
  ;; command with a silently altered argument is worse than not running it.
  (it "decode-command-payload-signals-on-malformed-argument-field"
    (let ((payload (make-array 5 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#x6C #x73 #x00 #xFF #x00))))
      (signals cl-codec-kit:decode-error
        (decode-command-payload payload))))

  ;; Regression guard on the decision itself: the malformed field must not come
  ;; back as a repaired string.  The SIGNALS tests above would also fail if the
  ;; command decoder were switched to :ERRORP NIL, but this one names the reason
  ;; — no byte the sender never wrote may become part of a command.
  (it "decode-command-payload-does-not-repair-malformed-bytes-into-a-command"
    (let ((payload (make-array 2 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#xFF #x00))))
      (expect (eq :refused
                  (handler-case (decode-command-payload payload)
                    (cl-codec-kit:decode-error () :refused))))))

  ;;; ── Display channel: lenient, repairs without signalling ────────────────────

  ;; DECODE-TEXT must survive the same bytes, because its callers (client.lisp
  ;; and client-command.lisp) establish no handler: signalling would take down
  ;; the user's attached terminal mid-render.
  (it "decode-text-does-not-signal-on-malformed-bytes"
    (let ((invalid   (make-array 1 :element-type '(unsigned-byte 8)
                                   :initial-contents '(#xFF)))
          (truncated (make-array 2 :element-type '(unsigned-byte 8)
                                   :initial-contents '(#xE3 #x81))))
      (finishes (decode-text invalid))
      (finishes (decode-text truncated))))

  ;; ...and must substitute U+FFFD specifically.  cl-codec-kit's :REPLACEMENT
  ;; default is (CODE-CHAR #x1A) (SUB) for encodings that declare no default of
  ;; their own, so this pins that the replacement is passed explicitly and
  ;; matches PARSER-OSC-DISPATCH.LISP rather than being inherited.
  (it "decode-text-substitutes-the-unicode-replacement-character"
    (let* ((invalid (make-array 1 :element-type '(unsigned-byte 8)
                                  :initial-contents '(#xFF)))
           (decoded (decode-text invalid)))
      (expect (= 1 (length decoded)))
      (expect (char= #\REPLACEMENT_CHARACTER (char decoded 0)))))

  ;; Leniency must not disturb the ordinary path: valid UTF-8 is unaffected.
  (it "decode-text-leaves-valid-utf-8-unchanged"
    (let ((bytes (cl-codec-kit:string-to-octets "hi あ" :encoding :utf-8)))
      (expect (string= "hi あ" (decode-text bytes)))))

  ;;; ── The guard that makes strictness safe ────────────────────────────────────

  ;; The end-to-end claim.  A same-uid peer sends a structurally VALID frame
  ;; whose payload is not UTF-8 — the cheapest possible attack on the socket.
  ;; The decode error must be absorbed by the event loop, cost exactly the one
  ;; client that sent it, and leave the session and every other client running.
  ;;
  ;; Only the offender's fd is placed in READY, so the quiet client is never read
  ;; from; its survival in *CLIENTS* is therefore a real isolation check and not
  ;; an artefact of the loop having skipped it.
  (it "dispatch-ready-clients-drops-only-the-sender-of-a-malformed-command-frame"
    (with-isolated-hooks
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

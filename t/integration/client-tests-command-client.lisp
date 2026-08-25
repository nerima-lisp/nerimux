(in-package #:nerimux/test)

(describe "client-suite"

  ;;; ── %maybe-send-resize behavior ──────────────────────────────────────────────
  ;;;
  ;;; %maybe-send-resize encapsulates the resize-pending check that was inline in
  ;;; run-client.  It is tested here using a socket pair so the msg-resize frame
  ;;; can be observed without a live terminal.

  ;; %maybe-send-resize sends a +msg-resize+ frame and clears *resize-pending*
  ;; when *resize-pending* is T — verifies the resize-dispatch path extracted from run-client.
  (it "maybe-send-resize-sends-frame-when-pending"
    (with-guarded-socket-test
      ;; Set resize-pending and known dimensions.
      (let ((nerimux::*resize-pending* t)
            (nerimux::*term-rows*      24)
            (nerimux::*term-cols*      80))
        ;; Call the helper with server-side as the stream to write on.
        (nerimux::%maybe-send-resize server-side)
        (force-output server-side)
        ;; The helper clears *resize-pending*.
        (expect nerimux::*resize-pending* :to-be-falsy)
        ;; A +msg-resize+ frame must be readable from the other end.
        (with-incoming-frame (type payload client-side)
          ((null type) (fail "%maybe-send-resize: got EOF instead of resize frame"))
          ((= type +msg-resize+)
           (multiple-value-bind (rows cols) (decode-size payload)
             (expect (= nerimux::*term-rows* rows))
             (expect (= nerimux::*term-cols* cols))))
          (t (fail "%maybe-send-resize: unexpected frame type ~D" type))))))

  ;; %maybe-send-resize is a no-op when *resize-pending* is NIL.
  (it "maybe-send-resize-does-nothing-when-not-pending"
    (let ((nerimux::*resize-pending* nil))
      (expect (nerimux::%maybe-send-resize nil) :to-be-falsy)))

  ;;; ── %forward-stdin-byte behavior ─────────────────────────────────────────────
  ;;;
  ;;; %forward-stdin-byte reads one non-blocking byte from fd 0 (stdin) and
  ;;; forwards it as a +msg-key+ frame.  We test the "nothing ready" branch
  ;;; (returns NIL without I/O) — the "byte forwarded" branch requires a real
  ;;; non-blocking stdin fd, which is unavailable in a sandboxed test runner.

  ;; %forward-stdin-byte returns NIL without error when stdin has no
  ;; data ready (non-blocking read returns nil).
  (it "forward-stdin-byte-returns-nil-when-nothing-ready"
    ;; read-byte-nonblock(0) on a non-blocking terminal returns NIL when no data
    ;; is ready.  In the test runner stdin is either /dev/null or a pipe with no
    ;; pending data — either way the function must return NIL without signalling.
    ;; Pass NIL as the stream so no socket write can happen even if the byte test
    ;; were to incorrectly find data.
    (let ((result (ignore-errors (nerimux::%forward-stdin-byte nil))))
      (expect (null result))))

  ;;; ── %run-attach-session peer-io-failure containment ──────────────────────────
  ;;;
  ;;; %run-attach-session (extracted from run-client) wraps its handshake sends
  ;;; and event loop in one HANDLER-CASE for PEER-IO-FAILURE (server.lisp) --
  ;;; (OR ERROR SB-EXT:TIMEOUT), not ERROR alone.  SEND-FRAME
  ;;; (infrastructure/net/transport.lisp) documents itself as signalling
  ;;; SB-EXT:TIMEOUT -- a SERIOUS-CONDITION that is deliberately NOT an ERROR --
  ;;; when a peer is too slow to accept a write, so this stubs SEND-FRAME to
  ;;; produce a genuine SB-EXT:TIMEOUT via SB-EXT:WITH-TIMEOUT (the same
  ;;; technique server-dispatch-helper-tests.lisp uses for
  ;;; WITH-LOOP-SAFE-ERROR) rather than a plain ERROR, so a regression back to
  ;;; an ERROR-only clause would fail this test even though it would still
  ;;; pass a weaker one written with (ERROR () ...).

  ;; A genuine SB-EXT:TIMEOUT from SEND-FRAME during the initial handshake is
  ;; contained: %run-attach-session returns normally (the condition does not
  ;; propagate to the caller) and reports the failure on *error-output*.
  (it "run-attach-session-contains-a-genuine-timeout-from-send-frame"
    (with-stubbed-fdefinition
        ((nerimux/transport:send-frame
          (lambda (&rest args)
            (declare (ignore args))
            (sb-ext:with-timeout 0.05 (sleep 5)))))
      (let (result reported)
        (setf reported
              (with-output-to-string (*error-output*)
                (setf result
                      (nerimux::%run-attach-session nil 99 nil))))
        ;; No condition escaped this call -- CL-WEAVE would report an
        ;; unhandled SB-EXT:TIMEOUT as a test error, not a failed EXPECT, so
        ;; simply reaching this line is part of the proof.
        (expect (null result))
        (expect (search "connection lost" reported)))))

  ;; An ordinary ERROR from SEND-FRAME is contained the same way as a timeout
  ;; -- PEER-IO-FAILURE is (OR ERROR SB-EXT:TIMEOUT), so the ERROR half of the
  ;; union must keep working too.
  (it "run-attach-session-contains-an-ordinary-error-from-send-frame"
    (with-stubbed-fdefinition
        ((nerimux/transport:send-frame
          (lambda (&rest args)
            (declare (ignore args))
            (error "socket write failed"))))
      (let (result reported)
        (setf reported
              (with-output-to-string (*error-output*)
                (setf result
                      (nerimux::%run-attach-session nil 99 nil))))
        (expect (null result))
        (expect (search "socket write failed" reported)))))

  ;;; ── send-kill-request peer-io-failure containment ────────────────────────────
  ;;;
  ;;; send-kill-request (the short one-shot `nerimux kill` control connection)
  ;;; treats a PEER-IO-FAILURE on its SEND-FRAME the same as :eof -- no reply
  ;;; arrived either way -- so RUN-KILL's existing "no reply from server"
  ;;; report (main-startup-commands.lisp) covers it without a second message.

  ;; A genuine SB-EXT:TIMEOUT from SEND-FRAME while sending the :kill command
  ;; is contained: send-kill-request returns (:eof NIL) instead of letting the
  ;; condition escape, and %read-kill-reply is never reached.
  (it "send-kill-request-maps-a-genuine-send-timeout-to-eof"
    (let (read-kill-reply-called)
      (with-stubbed-fdefinition
          ((nerimux::socket-path
            (lambda (name) (declare (ignore name)) "/tmp/nerimux-test-kill.sock"))
           (nerimux/net:connect-to
            (lambda (path) (declare (ignore path)) :socket))
           (nerimux/net:socket-stream
            (lambda (socket) (declare (ignore socket)) :stream))
           (nerimux/net:close-socket
            (lambda (socket) (declare (ignore socket))))
           (nerimux/transport:send-frame
            (lambda (&rest args)
              (declare (ignore args))
              (sb-ext:with-timeout 0.05 (sleep 5))))
           (nerimux::%read-kill-reply
            (lambda (stream)
              (declare (ignore stream))
              (setf read-kill-reply-called t)
              (values :reply (format nil "OK~%")))))
        (multiple-value-bind (status text) (nerimux::send-kill-request "0" nil)
          (expect (eq :eof status))
          (expect (null text))))
      (expect (null read-kill-reply-called)))))

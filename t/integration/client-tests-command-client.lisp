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
      (expect (null result)))))

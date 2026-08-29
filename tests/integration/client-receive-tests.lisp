(in-package #:nerimux/test)

;;;; Client receive/decode integration tests (src/client.lisp).
;;;;
;;;; Keep server-frame receive/decode behavior separate from outbound client
;;;; tests so cl-weave registers both suites independently.

(describe "client-receive-suite"

  ;; ── %decode-server-frame pure behavior ──────────────────────────────────────
  ;;
  ;; %decode-server-frame is the pure layer that %receive-server-frame calls.
  ;; These tests verify its dispositions without any I/O side effects.

  ;; %decode-server-frame returns (values :exit nil) when the server sends
  ;; +msg-bye+ — the pure classification step used by %receive-server-frame.
  (it "decode-server-frame-returns-exit-on-bye"
    (with-guarded-socket-test
      (send-frame server-side (msg-bye))
      (force-output server-side)
      (multiple-value-bind (disposition text)
          (nerimux::%decode-server-frame client-side)
        (expect (eq :exit disposition))
        (expect (null text)))))

  ;; %decode-server-frame returns (values :frame text) for +msg-frame+.
  ;; The pure step: caller decides whether/where to write the text.
  (it "decode-server-frame-returns-frame-and-text"
    (with-guarded-socket-test
      (send-frame server-side (msg-frame "PURE-TEXT"))
      (force-output server-side)
      (multiple-value-bind (disposition text)
          (nerimux::%decode-server-frame client-side)
        (expect (eq :frame disposition))
        (expect (string= "PURE-TEXT" text)))))

  (it "decode-server-frame-ignores-unknown-frame"
    (with-guarded-socket-test
      (write-sequence (encode-frame 255 #(1 2 3)) server-side)
      (force-output server-side)
      (multiple-value-bind (disposition text)
          (nerimux::%decode-server-frame client-side)
        (expect (eq :ignore disposition))
        (expect (null text)))))

  (it "receive-server-frame-ignores-unknown-disposition"
    (with-stubbed-fdefinition
        ((nerimux::%decode-server-frame
          (lambda (stream)
            (declare (ignore stream))
            (values :ignore nil))))
      (expect (null (nerimux::%receive-server-frame nil)))))

  ;; %decode-server-frame returns (values :exit nil) on EOF.
  (it "decode-server-frame-returns-exit-on-eof"
    (with-guarded-socket-test
      (close server-side)
      (sleep 0.05)
      (multiple-value-bind (disposition text)
          (nerimux::%decode-server-frame client-side)
        (expect (eq :exit disposition))
        (expect (null text)))))

  ;; ── %receive-server-frame behavior ──────────────────────────────────────────
  ;;
  ;; %receive-server-frame is the effect boundary that calls %decode-server-frame
  ;; and performs the actual write-string/force-output.

  ;; %receive-server-frame returns :exit when the server sends +msg-bye+.
  (it "receive-server-frame-returns-exit-on-bye"
    (with-guarded-socket-test
      (send-frame server-side (msg-bye))
      (force-output server-side)
      (expect (eq :exit (nerimux::%receive-server-frame client-side)))))

  ;; %receive-server-frame returns :exit on EOF (server closed the stream).
  (it "receive-server-frame-returns-exit-on-eof"
    (with-guarded-socket-test
      ;; Close the server-side stream to simulate server disconnect.
      (close server-side)
      ;; Give the stream close a moment to propagate across the socket.
      (sleep 0.05)
      (expect (eq :exit (nerimux::%receive-server-frame client-side)))))

  ;; %receive-server-frame writes +msg-frame+ content to *standard-output*
  ;; and returns NIL (continue the event loop).
  (it "receive-server-frame-paints-msg-frame-and-returns-nil"
    (with-guarded-socket-test
      (send-frame server-side (msg-frame "HELLO"))
      (force-output server-side)
      ;; Keep `expect` assertions OUTSIDE the with-output-to-string capture: any
      ;; runner progress/diagnostic output written to *standard-output* during an
      ;; assertion would otherwise contaminate `painted` (e.g. "HELLO." for a
      ;; captured "HELLO"), so we capture first and assert on the result after.
      (let (result)
        (let ((painted (with-output-to-string (*standard-output*)
                         (setf result (nerimux::%receive-server-frame client-side)))))
          (expect (null result))
          (expect (string= "HELLO" painted))))))

  ;; ── UTF-8 byte-width table-driven tests ─────────────────────────────────────
  ;;
  ;; %utf8-char-byte-count (the client-command-client's private UTF-8 byte-width
  ;; helper) was deleted along with the rest of the command-client CLI path.
  ;; The boundary table below survives by retargeting it at
  ;; cl-codec-kit:string-size-in-octets, the codec library's public equivalent —
  ;; it reports the same UTF-8 octet width for a single character, driven
  ;; through the actual encoder cl-codec-kit uses rather than a bespoke
  ;; reimplementation, so the four threshold boundaries (0x80, 0x800, 0x10000)
  ;; stay covered.

  ;; cl-codec-kit:string-size-in-octets returns the correct UTF-8 byte width for
  ;; boundary values in each of the four encoding ranges.  Tests at and just below
  ;; each threshold (0x80, 0x800, 0x10000) make the boundaries explicit.
  (it "utf8-char-byte-count-table"
    ;; Each row: (char-code expected-byte-count description)
    (dolist (row '((#x0000  1 "U+0000 is 1-byte (lowest codepoint)")
                   (#x0041  1 "U+0041 'A' is 1-byte ASCII")
                   (#x007F  1 "U+007F is 1-byte (just below 2-byte threshold 0x80)")
                   (#x0080  2 "U+0080 is 2-byte (exactly at 2-byte threshold)")
                   (#x00FF  2 "U+00FF is 2-byte (Latin-1 supplement)")
                   (#x07FF  2 "U+07FF is 2-byte (just below 3-byte threshold 0x800)")
                   (#x0800  3 "U+0800 is 3-byte (exactly at 3-byte threshold)")
                   (#x3042  3 "U+3042 hiragana is 3-byte")
                   (#xFFFF  3 "U+FFFF is 3-byte (just below 4-byte threshold 0x10000)")
                   (#x10000 4 "U+10000 is 4-byte (exactly at 4-byte threshold)")
                   (#x1F600 4 "U+1F600 emoji is 4-byte")))
      (destructuring-bind (code expected description) row
        (declare (ignore description))
        ;; Guard: skip codepoints beyond the Lisp image's char-code-limit.
        (when (< code char-code-limit)
          (let ((got (cl-codec-kit:string-size-in-octets
                      (string (code-char code)) :encoding :utf-8)))
            (expect (= expected got)))))))

  ;; ── %receive-if-ready behavior ──────────────────────────────────────────────
  ;;
  ;; %receive-if-ready is the event-loop glue that calls %receive-server-frame
  ;; only when the server fd appears in the ready set.  These tests cover the
  ;; "not ready" branch (returns NIL without I/O) and the "ready → delegates"
  ;; branch (returns :exit when the server sends +msg-bye+).

  ;; %receive-if-ready returns NIL without I/O when the server fd is
  ;; NOT in the READY list — the non-blocking guard must prevent reads on idle fds.
  (it "receive-if-ready-returns-nil-when-fd-not-in-ready-set"
    ;; Any fd value not in the ready list; NIL stream ensures no I/O if guard fails.
    (expect (null (nerimux::%receive-if-ready nil 99 '(0 1 2)))))

  ;; %receive-if-ready returns :exit when the server socket fd is in
  ;; the READY list and %receive-server-frame returns :exit (+msg-bye+ frame).
  (it "receive-if-ready-returns-exit-on-bye-when-fd-ready"
    (with-guarded-socket-test/fd (:server-stream server-stream :client-stream client-stream
                                   :client-fd client-fd)
      (send-frame server-stream (msg-bye))
      (force-output server-stream)
      ;; Wait for the frame to be readable.
      (nerimux/pty:select-fds (list client-fd) 1000000)
      ;; Ready set contains the client fd: %receive-if-ready must dispatch.
      (let ((result (nerimux::%receive-if-ready client-stream client-fd
                                                (list client-fd))))
        (expect (eq :exit result))))))

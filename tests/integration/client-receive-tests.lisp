(in-package #:nerimux/test)

(describe "client-receive-suite"


  (it "decode-server-frame-returns-exit-on-bye"
    (with-guarded-socket-test
      (send-frame server-side (msg-bye))
      (force-output server-side)
      (multiple-value-bind (disposition text)
          (nerimux::%decode-server-frame client-side)
        (expect (eq :exit disposition))
        (expect (null text)))))

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

  (it "decode-server-frame-returns-exit-on-eof"
    (with-guarded-socket-test
      (close server-side)
      (sleep 0.05)
      (multiple-value-bind (disposition text)
          (nerimux::%decode-server-frame client-side)
        (expect (eq :exit disposition))
        (expect (null text)))))


  (it "receive-server-frame-returns-exit-on-bye"
    (with-guarded-socket-test
      (send-frame server-side (msg-bye))
      (force-output server-side)
      (expect (eq :exit (nerimux::%receive-server-frame client-side)))))

  (it "receive-server-frame-returns-exit-on-eof"
    (with-guarded-socket-test
      (close server-side)
      (sleep 0.05)
      (expect (eq :exit (nerimux::%receive-server-frame client-side)))))

  (it "receive-server-frame-paints-msg-frame-and-returns-nil"
    (with-guarded-socket-test
      (send-frame server-side (msg-frame "HELLO"))
      (force-output server-side)
      (let (result)
        (let ((painted (with-output-to-string (*standard-output*)
                         (setf result (nerimux::%receive-server-frame client-side)))))
          (expect (null result))
          (expect (string= "HELLO" painted))))))


  (it "utf8-char-byte-count-table"
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
        (when (< code char-code-limit)
          (let ((got (cl-codec-kit:string-size-in-octets
                      (string (code-char code)) :encoding :utf-8)))
            (expect (= expected got)))))))


  (it "receive-if-ready-returns-nil-when-fd-not-in-ready-set"
    (expect (null (nerimux::%receive-if-ready nil 99 '(0 1 2)))))

  (it "receive-if-ready-returns-exit-on-bye-when-fd-ready"
    (with-guarded-socket-test/fd (:server-stream server-stream :client-stream client-stream
                                   :client-fd client-fd)
      (send-frame server-stream (msg-bye))
      (force-output server-stream)
      (nerimux/pty:select-fds (list client-fd) 1000000)
      (let ((result (nerimux::%receive-if-ready client-stream client-fd
                                                (list client-fd))))
        (expect (eq :exit result))))))

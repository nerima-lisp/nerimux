(in-package #:nerimux/test/net)

(describe "protocol-command-malformed-utf8-suite"


  (it "split-on-nul-bytes-signals-on-invalid-leading-byte"
    (let ((payload (make-array 2 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#xFF #x00))))
      (signals cl-codec-kit:decode-error
        (nerimux/protocol:split-on-nul-bytes payload))))

  (it "split-on-nul-bytes-signals-on-truncated-sequence"
    (let ((payload (make-array 3 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#xE3 #x81 #x00))))
      (signals cl-codec-kit:decode-error
        (nerimux/protocol:split-on-nul-bytes payload))))

  (it "decode-command-payload-signals-on-malformed-argument-field"
    (let ((payload (make-array 5 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#x6C #x73 #x00 #xFF #x00))))
      (signals cl-codec-kit:decode-error
        (decode-command-payload payload))))

  (it "decode-command-payload-does-not-repair-malformed-bytes-into-a-command"
    (let ((payload (make-array 2 :element-type '(unsigned-byte 8)
                                 :initial-contents '(#xFF #x00))))
      (expect (eq :refused
                  (handler-case (decode-command-payload payload)
                    (cl-codec-kit:decode-error () :refused))))))


  (it "decode-text-does-not-signal-on-malformed-bytes"
    (let ((invalid   (make-array 1 :element-type '(unsigned-byte 8)
                                   :initial-contents '(#xFF)))
          (truncated (make-array 2 :element-type '(unsigned-byte 8)
                                   :initial-contents '(#xE3 #x81))))
      (finishes (decode-text invalid))
      (finishes (decode-text truncated))))

  (it "decode-text-substitutes-the-unicode-replacement-character"
    (let* ((invalid (make-array 1 :element-type '(unsigned-byte 8)
                                  :initial-contents '(#xFF)))
           (decoded (decode-text invalid)))
      (expect (= 1 (length decoded)))
      (expect (char= #\REPLACEMENT_CHARACTER (char decoded 0)))))

  (it "decode-text-leaves-valid-utf-8-unchanged"
    (let ((bytes (cl-codec-kit:string-to-octets "hi あ" :encoding :utf-8)))
      (expect (string= "hi あ" (decode-text bytes)))))
)

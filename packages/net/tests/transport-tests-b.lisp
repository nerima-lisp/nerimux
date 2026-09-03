(in-package #:nerimux/test/net)

(defun %make-frame-with-declared-length (declared-payload-length
                                         actual-payload-bytes)
  "Build a frame whose 4-byte length field claims DECLARED-PAYLOAD-LENGTH bytes
   but whose actual body contains ACTUAL-PAYLOAD-BYTES bytes of (zero-filled) payload.
   Byte 0 carries the +msg-frame+ type tag; bytes 1-4 are the overwritten length
   field; the remainder is zeroed payload.
   Used to construct both mismatched-length frames (declared != actual) and
   oversized-declared frames (declared > +max-frame-payload-bytes+)."
  (let* ((total (+ +header-size+ actual-payload-bytes))
         (frame
          (make-array total :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref frame 0) +msg-frame+)
    (replace frame
             (nerimux/protocol:u32-octets declared-payload-length)
             :start1
             1)
    frame))

(describe "transport-suite"


  (it "send-frame-rejects-too-short-frames"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (signals error
          (send-frame out (make-array 3 :element-type '(unsigned-byte 8)))
          "send-frame with a 3-byte frame (shorter than 5-byte header) must signal"))))

  (it "send-frame-rejects-length-field-mismatch"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (signals error
          (send-frame out (%make-frame-with-declared-length 10 0))
          "declared=10 actual=0 must signal (header claims more bytes than present)")
        (signals error
          (send-frame out (%make-frame-with-declared-length 1 5))
          "declared=1 actual=5 must signal (header claims fewer bytes than present)"))))

  (it "send-frame-rejects-oversized-declared-payload-length"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (signals error
          (send-frame out (%make-frame-with-declared-length
                           (1+ nerimux/transport::+max-frame-payload-bytes+)
                           0))
          "declared length = max+1 must signal (exceeds +max-frame-payload-bytes+)")
        (signals error
          (send-frame out (%make-frame-with-declared-length #xFFFFFFFF 0))
          "declared length = 0xFFFFFFFF must signal (far exceeds +max-frame-payload-bytes+)"))))


  (it "payload-length-acceptable-p-accepts-valid-lengths"
    (expect (nerimux/transport::%payload-length-acceptable-p 0) :to-be-truthy)
    (expect (nerimux/transport::%payload-length-acceptable-p 1) :to-be-truthy)
    (expect (nerimux/transport::%payload-length-acceptable-p
             nerimux/transport::+max-frame-payload-bytes+)
            :to-be-truthy))

  (it "payload-length-acceptable-p-rejects-oversized-lengths"
    (expect (nerimux/transport::%payload-length-acceptable-p -1) :to-be-falsy)
    (expect (nerimux/transport::%payload-length-acceptable-p
             (1+ nerimux/transport::+max-frame-payload-bytes+))
            :to-be-falsy)
    (expect (nerimux/transport::%payload-length-acceptable-p #xFFFFFFFF) :to-be-falsy))


  (it "read-frame-rejects-oversized-declared-payload-in-stream"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (let* ((oversized-length (1+ nerimux/transport::+max-frame-payload-bytes+))
               (header (make-array +header-size+ :element-type '(unsigned-byte 8)
                                                 :initial-element 0)))
          (setf (aref header 0) +msg-frame+)
          (replace header (nerimux/protocol:u32-octets oversized-length) :start1 1)
          (write-sequence header out)))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (expect (null (read-frame in))))))

  (it "read-frame-rejects-max-u32-declared-payload-in-stream"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (let ((header (make-array +header-size+ :element-type '(unsigned-byte 8)
                                                :initial-element 0)))
          (setf (aref header 0) +msg-frame+)
          (replace header (nerimux/protocol:u32-octets #xFFFFFFFF) :start1 1)
          (write-sequence header out)))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (expect (null (read-frame in))))))


  (it "validate-outgoing-frame-accepts-well-formed-frames"
    (finishes (nerimux/transport::%validate-outgoing-frame (msg-detach))
              "%validate-outgoing-frame must not signal for a valid empty frame")
    (finishes (nerimux/transport::%validate-outgoing-frame (msg-key #(1 2 3)))
              "%validate-outgoing-frame must not signal for a valid key frame")
    (finishes (nerimux/transport::%validate-outgoing-frame (msg-resize 24 80))
              "%validate-outgoing-frame must not signal for a valid resize frame"))

  (it "validate-outgoing-frame-rejects-too-short-vector"
    (signals error
      (nerimux/transport::%validate-outgoing-frame
       (make-array 0 :element-type '(unsigned-byte 8)))
      "empty vector must signal")
    (signals error
      (nerimux/transport::%validate-outgoing-frame
       (make-array (1- +header-size+) :element-type '(unsigned-byte 8)))
      "vector shorter than header must signal"))

  (it "validate-outgoing-frame-rejects-oversized-declared-length"
    (signals error
      (nerimux/transport::%validate-outgoing-frame
       (%make-frame-with-declared-length
        (1+ nerimux/transport::+max-frame-payload-bytes+) 0))
      "declared length = max+1 must signal"))

  (it "validate-outgoing-frame-rejects-self-inconsistent-length"
    (signals error
      (nerimux/transport::%validate-outgoing-frame
       (%make-frame-with-declared-length 5 0))
      "declared=5 actual=0 must signal (header claims more bytes than present)")
    (signals error
      (nerimux/transport::%validate-outgoing-frame
       (%make-frame-with-declared-length 0 3))
      "declared=0 actual=3 must signal (header claims fewer bytes than present)"))


  (it "read-header-k-calls-continuation-with-payload-length"
    (let ((frame (msg-key #(1 2 3))))   ; 5-byte header + 3-byte payload
      (with-temp-octet-file (path)
        (with-output-octet-stream (out path)
          (write-sequence frame out :end +header-size+))
        (with-open-file (in path :element-type '(unsigned-byte 8))
          (let ((captured-length nil))
            (nerimux/transport::%read-header-k
             in
             (lambda (buffer payload-length)
               (declare (ignore buffer))
               (setf captured-length payload-length)))
            (expect (= 3 captured-length)))))))

  (it "read-header-k-returns-nil-at-eof"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (write-sequence #(1 2 3) out))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((called nil))
          (let ((result
                 (nerimux/transport::%read-header-k
                  in
                  (lambda (buffer payload-length)
                    (declare (ignore buffer payload-length))
                    (setf called t)
                    :called))))
            (expect (null result))
            (expect (null called)))))))

  (it "read-header-k-returns-nil-for-oversized-declared-payload"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (let* ((oversized (1+ nerimux/transport::+max-frame-payload-bytes+))
               (header    (make-array +header-size+ :element-type '(unsigned-byte 8)
                                                    :initial-element 0)))
          (setf (aref header 0) +msg-frame+)
          (replace header (nerimux/protocol:u32-octets oversized) :start1 1)
          (write-sequence header out)))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((called nil))
          (let ((result
                 (nerimux/transport::%read-header-k
                  in
                  (lambda (buffer payload-length)
                    (declare (ignore buffer payload-length))
                    (setf called t)
                    :called))))
            (expect (null result))
            (expect (null called)))))))


  (it "read-payload-k-calls-continuation-with-complete-buffer"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (write-sequence #(10 20 30 40) out))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let* ((header-buf (make-array +header-size+ :element-type '(unsigned-byte 8)
                                                     :adjustable t
                                                     :fill-pointer +header-size+))
               (captured nil))
          (nerimux/transport::%read-payload-k
           header-buf 4 in
           (lambda (complete-buffer)
             (setf captured (subseq complete-buffer +header-size+))))
          (expect (equalp #(10 20 30 40) captured))))))

  (it "read-payload-k-returns-nil-at-eof"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (write-sequence #(1 2) out))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let* ((header-buf (make-array +header-size+ :element-type '(unsigned-byte 8)
                                                     :adjustable t
                                                     :fill-pointer +header-size+))
               (called nil))
          (let ((result
                 (nerimux/transport::%read-payload-k
                  header-buf 4 in
                  (lambda (complete-buffer)
                    (declare (ignore complete-buffer))
                    (setf called t)
                    :called))))
            (expect (null result))
            (expect (null called))))))))

(describe "transport-timeout-suite"
          (it "read-frame-returns-nil-on-transport-timeout"
              (with-stubbed-fdefinition
               ((nerimux/transport::%read-header-k
                 (lambda (stream continuation)
                   (declare (ignore stream continuation))
                   (error 'sb-ext:timeout))))
               (with-temp-octet-file (path)
                                     (with-open-file 
                                         (in path
                                             :element-type
                                             '(unsigned-byte 8)
                                             :if-does-not-exist
                                             :create)
                                       (expect (null (read-frame in))))))))

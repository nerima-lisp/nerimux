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
    (let ((frame (msg-key #(1 2 3))))
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
            (expect (null called)))))))
  (it "read-frame-ready-preserves-short-header-and-payload-reads"
    (let* ((reader (nerimux/transport:make-frame-reader))
           (frame (msg-key #(1 2 3))))
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (declare (ignore listener))
          (multiple-value-bind (type payload status)
              (nerimux/transport:read-frame-ready reader conn :max-bytes 2)
            (expect (null type))
            (expect (null payload))
            (expect (eql :would-block status)))
          (expect (= 2 (sb-bsd-sockets:socket-send client frame 2 :dontwait t :nosignal t)))
          (multiple-value-bind (type payload status)
              (nerimux/transport:read-frame-ready reader conn :max-bytes 2)
            (expect (null type))
            (expect (null payload))
            (expect (eql :pending status)))
          (expect (= 3 (sb-bsd-sockets:socket-send
                        client (subseq frame 2 5) 3 :dontwait t :nosignal t)))
          (multiple-value-bind (type payload status)
              (nerimux/transport:read-frame-ready reader conn :max-bytes 3)
            (expect (null type))
            (expect (null payload))
            (expect (eql :pending status)))
          (expect (= 3 (nerimux/transport:frame-reader-payload-size reader)))
          (expect (= 1 (sb-bsd-sockets:socket-send
                        client (subseq frame 5 6) 1 :dontwait t :nosignal t)))
          (multiple-value-bind (type payload status)
              (nerimux/transport:read-frame-ready reader conn :max-bytes 1)
            (expect (null type))
            (expect (null payload))
            (expect (eql :pending status)))
          (expect (= 2 (sb-bsd-sockets:socket-send
                        client (subseq frame 6) 2 :dontwait t :nosignal t)))
          (multiple-value-bind (type payload status)
              (nerimux/transport:read-frame-ready reader conn :max-bytes 2)
            (expect (= +msg-key+ type))
            (expect (equalp #(1 2 3) payload))
            (expect (eql :frame status)))
          (expect (null (nerimux/transport:frame-reader-payload-size reader)))))))

  (it "read-frame-ready-rejects-oversized-length-before-payload-allocation"
    (let* ((reader (nerimux/transport:make-frame-reader))
           (header (make-array +header-size+ :element-type '(unsigned-byte 8)
                                             :initial-element 0))
           (oversized (1+ nerimux/transport::+max-frame-payload-bytes+)))
      (setf (aref header 0) +msg-frame+)
      (replace header (nerimux/protocol:u32-octets oversized) :start1 1)
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-receive
            (lambda (socket buffer length &key dontwait element-type)
              (declare (ignore socket dontwait element-type))
              (replace buffer header :end1 length)
              (values buffer length nil))))
        (signals error
          (nerimux/transport:read-frame-ready reader nil)
          "incremental reader must reject oversized header")
        (expect (= +header-size+
                   (length (nerimux/transport::frame-reader-buffer reader))))
        (expect (nerimux/transport::frame-reader-failed-p reader)))))
  (it "write-frame-ready-retains-offset-across-short-write-and-would-block"
    (let ((writer (nerimux/transport:make-frame-writer))
          (calls 0))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket buffer dontwait nosignal))
              (incf calls)
              (case calls
                (1 (expect (= 2 length)) 2)
                (2 (error (make-condition 'sb-bsd-sockets:socket-error
                                          :errno sb-posix:eagain)))
                (3 (expect (= 3 length)) 3)
                (otherwise (error "unexpected socket-send call"))))))
        (nerimux/transport:start-frame-write writer (msg-detach))
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes 2)
          (expect (eql :pending status))
          (expect (= 2 bytes-written))
          (expect (= 2 (nerimux/transport:frame-writer-offset writer))))
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes 2)
          (expect (eql :would-block status))
          (expect (zerop bytes-written))
          (expect (= 2 (nerimux/transport:frame-writer-offset writer))))
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes 3)
          (expect (eql :complete status))
          (expect (= 3 bytes-written))
          (expect (zerop (nerimux/transport:frame-writer-offset writer)))
          (expect (not (nerimux/transport:frame-writer-pending-p writer))))
        (expect (= 3 calls)))))
  (it "write-frame-ready-fails-writer-after-partial-fatal-error"
    (let ((writer (nerimux/transport:make-frame-writer))
          (calls 0))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket buffer length dontwait nosignal))
              (incf calls)
              (case calls
                (1 2)
                (2 (error (make-condition 'sb-bsd-sockets:socket-error
                                          :errno sb-posix:epipe)))
                (otherwise (error "unexpected socket-send call"))))))
        (nerimux/transport:start-frame-write writer (msg-detach))
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes 2)
          (expect (eql :pending status))
          (expect (= 2 bytes-written)))
        (signals sb-bsd-sockets:socket-error
          (nerimux/transport:write-frame-ready writer nil :max-bytes 3)
          "fatal error after a partial frame must be re-signalled")
        (expect (= 2 (nerimux/transport:frame-writer-offset writer)))
        (expect (nerimux/transport:frame-writer-failed-p writer))
        (signals error
          (nerimux/transport:start-frame-write writer (msg-detach))
          "failed writer must not accept another frame")
        (expect (= 2 calls)))))
  (it "start-frame-write-rejects-interleaving-until-prior-frame-completes"
    (let* ((writer (nerimux/transport:make-frame-writer))
           (first-frame (msg-detach))
           (second-frame (msg-key #(9)))
           (sent (make-array 0 :element-type '(unsigned-byte 8))))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket dontwait nosignal))
              (setf sent
                    (concatenate '(vector (unsigned-byte 8))
                                 sent
                                 (subseq buffer 0 length)))
              length)))
        (nerimux/transport:start-frame-write writer first-frame)
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes 2)
          (expect (eql :pending status))
          (expect (= 2 bytes-written)))
        (signals error
          (nerimux/transport:start-frame-write writer second-frame)
          "a second frame must wait for the active frame to finish")
        (expect (= 2 (nerimux/transport:frame-writer-offset writer)))
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes 3)
          (expect (eql :complete status))
          (expect (= 3 bytes-written)))
        (nerimux/transport:start-frame-write writer second-frame)
        (multiple-value-bind (status bytes-written)
            (nerimux/transport:write-frame-ready writer nil :max-bytes (length second-frame))
          (expect (eql :complete status))
          (expect (= (length second-frame) bytes-written)))
        (expect (equalp (concatenate '(vector (unsigned-byte 8))
                                     first-frame second-frame)
                        sent))))))

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

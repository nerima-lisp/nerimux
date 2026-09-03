(in-package #:nerimux/test/net)

(describe "transport-suite"

  (it "transport-roundtrips-a-frame"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-resize 24 80))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-resize+ type))
          (multiple-value-bind (rows cols) (decode-size payload)
            (expect (= 24 rows))
            (expect (= 80 cols)))))))

  (it "transport-reads-sequential-frames"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-key #(65 66)) (msg-detach) (msg-frame "hi あ"))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-key+ type))
          (expect (equalp #(65 66) payload)))
        (multiple-value-bind (type payload) (read-frame in)
          (declare (ignore payload))
          (expect (= +msg-detach+ type)))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-frame+ type))
          (expect (string= "hi あ" (decode-text payload)))))))

  (it "transport-read-at-eof-returns-nil"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-detach))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (multiple-value-bind (type payload) (read-frame in)
          (declare (ignore payload))
          (expect (= +msg-detach+ type)))
        (expect (null (read-frame in))))))

  (it "transport-truncated-frame-returns-nil"
    (with-temp-octet-file (path)
      (let ((frame (msg-key #(1 2 3))))
        (write-partial-frame-to-file path frame 4))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (expect (null (read-frame in))))))

  (it "transport-truncated-payload-returns-nil"
    (with-temp-octet-file (path)
      (let ((frame (msg-key #(1 2 3))))
        (expect (= 8 (length frame)))
        (write-partial-frame-to-file path frame 6))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (expect (null (read-frame in))))))

  (it "transport-empty-payload-frame-roundtrips"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-detach))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-detach+ type))
          (expect (zerop (length payload)))))))

  (it "transport-roundtrips-attach-and-bye-frames"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-attach 30 120) (msg-bye))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-attach+ type))
          (multiple-value-bind (rows cols) (decode-size payload)
            (expect (= 30 rows))
            (expect (= 120 cols))))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-bye+ type))
          (expect (zerop (length payload))))
        (expect (null (read-frame in))))))


  (it "with-incoming-frame-dispatches-on-type"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-detach))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((dispatched nil))
          (with-incoming-frame (type payload in)
            ((= type +msg-detach+) (expect (zerop (length payload)))
                                   (setf dispatched :detach))
            (t (setf dispatched :other)))
          (expect (eq :detach dispatched))))))

  (it "with-incoming-frame-binds-payload"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-key #(65 66 67)))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((captured nil))
          (with-incoming-frame (type payload in)
            ((= type +msg-key+) (setf captured payload))
            (t nil))
          (expect (equalp #(65 66 67) captured))))))

  (it "with-incoming-frame-eof-falls-through-to-nil-type"
    (with-temp-octet-file (path)
      (with-open-file (in path :element-type '(unsigned-byte 8)
                               :if-does-not-exist :create)
        (let ((hit-eof nil))
          (with-incoming-frame (type payload in)
            ((null type) (expect (null payload))
                         (setf hit-eof t))
            (t nil))
          (expect hit-eof :to-be-truthy)))))

  (it "with-incoming-frame-first-matching-clause-wins"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-resize 10 20))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((result nil))
          (with-incoming-frame (type payload in)
            ((= type +msg-resize+)
             (multiple-value-bind (rows cols)
                 (nerimux/protocol:decode-size payload)
               (setf result (list :resize rows cols))))
            ((= type +msg-key+)   (setf result :key))
            (t                    (setf result :other)))
          (expect (equal '(:resize 10 20) result))))))


  (it "transport-all-typed-constructors-roundtrip"
    (assert-round-tripped-frame-type (msg-attach  24 80)           +msg-attach+)
    (assert-round-tripped-frame-type (msg-key     #(27 65))        +msg-key+)
    (assert-round-tripped-frame-type (msg-resize  30 100)          +msg-resize+)
    (assert-round-tripped-frame-type (msg-detach)                  +msg-detach+)
    (assert-round-tripped-frame-type (msg-frame   "hi")            +msg-frame+)
    (assert-round-tripped-frame-type (msg-bye)                     +msg-bye+)
    (assert-round-tripped-frame-type (msg-reply   "output text")   +msg-reply+)
    (assert-round-tripped-frame-type (msg-command :new-window nil nil) +msg-command+))

  (it "transport-typed-constructors-payload-roundtrip"
    (assert-round-tripped-frame-payload
     (msg-attach 15 60)
     (lambda (payload)
       (multiple-value-bind (rows cols) (nerimux/protocol:decode-size payload)
         (expect (= 15 rows))
         (expect (= 60 cols)))))
    (assert-round-tripped-frame-payload
     (msg-key #(27 91 65))
     (lambda (payload)
       (expect (equalp #(27 91 65) payload))))
    (assert-round-tripped-frame-payload
     (msg-resize 50 200)
     (lambda (payload)
       (multiple-value-bind (rows cols) (nerimux/protocol:decode-size payload)
         (expect (= 50 rows))
         (expect (= 200 cols)))))
    (assert-round-tripped-frame-payload
     (msg-frame "こんにちは")
     (lambda (payload)
       (expect (string= "こんにちは" (nerimux/protocol:decode-text payload)))))
    (assert-round-tripped-frame-payload
     (msg-reply "output: 42")
     (lambda (payload)
       (expect (string= "output: 42" (nerimux/protocol:decode-text payload)))))
    (assert-round-tripped-frame-payload
     (msg-command :new-window "$0" '("-d"))
     (lambda (payload)
       (multiple-value-bind (command target args)
           (nerimux/protocol:decode-command-payload payload)
         (expect (eq :new-window command))
         (expect (string= "$0" target))
         (expect (equal '("-d") args))))))


  (it "transport-msg-command-frame-roundtrips"
    (with-temp-octet-file (path)
      (write-frames-to-file path (msg-command :new-session "$0" '("-d" "-s" "main")))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (multiple-value-bind (type payload) (read-frame in)
          (expect (= +msg-command+ type))
          (multiple-value-bind (command target args)
              (nerimux/protocol:decode-command-payload payload)
            (expect (eq :new-session command))
            (expect (string= "$0" target))
            (expect (equal '("-d" "-s" "main") args)))))))


  (it "transport-large-payload-roundtrips"
    (let* ((n       65536)
           (payload (make-array n :element-type '(unsigned-byte 8))))
      (dotimes (i n) (setf (aref payload i) (logand i #xFF)))
      (with-temp-octet-file (path)
        (write-frames-to-file path (encode-frame +msg-frame+ payload))
        (with-open-file (in path :element-type '(unsigned-byte 8))
          (multiple-value-bind (type decoded) (read-frame in)
            (expect (= +msg-frame+ type))
            (expect (= n (length decoded)))
            (expect (equalp payload decoded)))))))


  (it "send-frame-finishes-without-signalling"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (finishes (send-frame out (msg-detach))
                  "send-frame must not signal on a valid binary output stream"))))


  (it "read-frame-timeout-constant-is-positive-integer"
    (expect (integerp nerimux/transport::+read-frame-timeout-seconds+))
    (expect (plusp nerimux/transport::+read-frame-timeout-seconds+)))

  (it "max-frame-payload-constant-is-large-positive-integer"
    (expect (integerp nerimux/transport::+max-frame-payload-bytes+))
    (expect (>= nerimux/transport::+max-frame-payload-bytes+ (* 1024 1024))))


  (it "read-exact-fills-buffer-exactly"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (write-sequence #(10 20 30 40 50 60 70 80 90 100) out))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((buffer (make-array 10 :element-type '(unsigned-byte 8))))
          (let ((bytes-read (nerimux/transport::%read-exact buffer in 0 10)))
            (expect (= 10 bytes-read))
            (expect (equalp #(10 20 30 40 50 60 70 80 90 100) buffer)))))))

  (it "read-exact-returns-short-count-at-eof"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (write-sequence #(1 2 3) out))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((buffer (make-array 10 :element-type '(unsigned-byte 8) :initial-element 0)))
          (let ((bytes-read (nerimux/transport::%read-exact buffer in 0 10)))
            (expect (< bytes-read 10))
            (expect (= 3 bytes-read)))))))

  (it "read-exact-respects-start-offset"
    (with-temp-octet-file (path)
      (with-output-octet-stream (out path)
        (write-sequence #(7 8 9) out))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (let ((buffer (make-array 6 :element-type '(unsigned-byte 8) :initial-element 0)))
          (nerimux/transport::%read-exact buffer in 3 6)
          (expect (= 0 (aref buffer 0)))
          (expect (= 0 (aref buffer 1)))
          (expect (= 0 (aref buffer 2)))
          (expect (= 7 (aref buffer 3)))
          (expect (= 8 (aref buffer 4)))
          (expect (= 9 (aref buffer 5))))))))

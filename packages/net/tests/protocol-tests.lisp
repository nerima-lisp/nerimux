(in-package #:nerimux/test/net)

(describe "protocol-suite"

  (it-each (((1 read 16 "invalid encoder name"))
            ((encode 1 16 "invalid decoder name"))
            ((encode read 7 "invalid bit width"))
            ((encode read 0 "zero bit width"))
            ((encode read -8 "negative bit width"))
            ((encode read foo "non-integer bit width"))
            ((encode read 16 42 "invalid documentation"))
            (())
            ((encode read 16 "documentation" :unexpected)))
      "define-uint-codec-rejects-invalid-schema ~S"
      (spec)
    (signals error
      (macroexpand-1
       `(nerimux/protocol::define-uint-codec ,spec))))


  (it-each ((0     #(0 0))
            (1     #(0 1))
            (256   #(1 0))
            (65535 #(255 255)))
      "u16-octets-big-endian ~A"
      (n expected)
    (expect (equalp expected (nerimux/protocol:u16-octets n))))

  (it-each ((0          #(0 0 0 0))
            (1          #(0 0 0 1))
            (65536      #(0 1 0 0))
            (#xFFFFFFFF #(255 255 255 255)))
      "u32-octets-big-endian ~A"
      (n expected)
    (expect (equalp expected (nerimux/protocol:u32-octets n))))

  (it "u16-octets-pair-concatenates-two-u16s"
    (expect (equalp #(0 24 0 80) (nerimux/protocol:u16-octets-pair 24 80)))
    (expect (equalp #(0 0 0 0)   (nerimux/protocol:u16-octets-pair 0 0))))

  (it-each ((0 0  "offset 0 → 0")
            (2 24 "offset 2 → 24")
            (4 80 "offset 4 → 80"))
      "read-u16-decodes-big-endian: ~*~A"
      (offset expected desc)
    (declare (ignore desc))
    (let ((buffer (make-array 6 :element-type '(unsigned-byte 8)
                                :initial-contents '(0 0 0 24 0 80))))
      (expect (= expected (nerimux/protocol:read-u16 buffer offset)))))


  (defun cat-octets (&rest frames)
    "Concatenate octet vectors into one simple octet buffer (a wire stream)."
    (apply #'concatenate '(simple-array (unsigned-byte 8) (*)) frames))


  (it "frame-header-layout"
    (let ((frame (encode-frame +msg-key+ (to-octets #(7 8 9)))))
      (expect (= +header-size+ 5))
      (expect (= +msg-key+ (aref frame 0)))
      (expect (equalp #(0 0 0 3) (subseq frame 1 5)))
      (expect (= 8 (length frame)))))


  (it "attach-roundtrip"
    (let ((frame (msg-attach 24 80)))
      (assert-decoded-frame-type frame +msg-attach+)
      (assert-decoded-frame-payload
       frame
       (lambda (payload)
         (multiple-value-bind (rows cols) (decode-size payload)
           (expect (= 24 rows))
           (expect (= 80 cols)))))))

  (it "resize-roundtrip"
    (let ((frame (msg-resize 300 1000)))
      (assert-decoded-frame-type frame +msg-resize+)
      (assert-decoded-frame-payload
       frame
       (lambda (payload)
         (multiple-value-bind (rows cols) (decode-size payload)
           (expect (= 300 rows))
           (expect (= 1000 cols)))))))

  (it "key-roundtrip"
    (let ((frame (msg-key #(27 91 65))))
      (assert-decoded-frame-type frame +msg-key+)
      (assert-decoded-frame-payload
       frame
       (lambda (payload) (expect (equalp #(27 91 65) payload))))))

  (it "detach-and-bye-are-empty"
    (multiple-value-bind (type payload next) (decode-frame (msg-detach))
      (expect (= +msg-detach+ type))
      (expect (= 0 (length payload)))
      (expect (= +header-size+ next)))
    (assert-decoded-frame-type (msg-bye) +msg-bye+)
    (assert-decoded-frame-payload (msg-bye) (lambda (payload) (expect (= 0 (length payload))))))

  (it "frame-text-roundtrip"
    (let* ((text "hello あ 中 │")
           (frame (msg-frame text)))
      (assert-decoded-frame-type frame +msg-frame+)
      (assert-decoded-frame-payload
       frame
       (lambda (payload) (expect (string= text (decode-text payload)))))))

  (it "reply-text-roundtrip"
    (let* ((text "session: 0  windows: 2")
           (frame (msg-reply text)))
      (assert-decoded-frame-type frame +msg-reply+)
      (assert-decoded-frame-payload
       frame
       (lambda (payload)
         (expect (string= text (decode-text payload)))))))

  (it "decode-text-replaces-malformed-utf8"
    (expect (string= (format nil "A~Cz" #\REPLACEMENT_CHARACTER)
                    (decode-text #(65 255 122)))))


  (it "decode-incomplete-header-returns-nil"
    (let ((frame (msg-resize 10 20)))
      (multiple-value-bind (type payload next) (decode-frame frame 0 3)
        (expect (null type))
        (expect (null payload))
        (expect (= 0 next)))))

  (it "decode-incomplete-payload-returns-nil"
    (let ((frame (msg-key #(1 2 3 4 5 6))))   ; header(5) + 6 payload = 11 bytes
      (expect (null (decode-frame frame 0 (1- (length frame)))))))


  (it "decode-back-to-back-frames"
    (let* ((buffer (cat-octets (msg-detach)
                               (msg-key #(65 66))
                               (msg-resize 5 9))))
      (multiple-value-bind (type payload next1) (decode-frame buffer)
        (declare (ignore payload))
        (expect (= +msg-detach+ type))
        (multiple-value-bind (type2 payload2 next2) (decode-frame buffer next1)
          (expect (= +msg-key+ type2))
          (expect (equalp #(65 66) payload2))
          (multiple-value-bind (type3 payload3 next3) (decode-frame buffer next2)
            (expect (= +msg-resize+ type3))
            (multiple-value-bind (rows cols) (decode-size payload3)
              (expect (= 5 rows))
              (expect (= 9 cols)))
            (expect (= (length buffer) next3)))))))


  (it-each ((256) (1000) (65536))
      "frame-codec-large-payload-roundtrip ~A"
      (n)
    (let* ((payload (make-array n :element-type '(unsigned-byte 8))))
      (dotimes (i n)
        (setf (aref payload i) (logand i #xFF)))
      (let ((frame (encode-frame +msg-frame+ payload)))
        (expect (= (+ +header-size+ n) (length frame)))
        (expect (= n (nerimux/protocol:read-u32 frame 1)))
        (multiple-value-bind (type decoded next) (decode-frame frame)
          (expect (= +msg-frame+ type))
          (expect (= n (length decoded)))
          (expect (equalp payload decoded))
          (expect (= (length frame) next))))))

  (it "frame-codec-two-large-frames-next-index"
    (let* ((p1 (make-array 1000  :element-type '(unsigned-byte 8)))
           (p2 (make-array 65536 :element-type '(unsigned-byte 8))))
      (dotimes (i 1000)  (setf (aref p1 i) (logand i #xFF)))
      (dotimes (i 65536) (setf (aref p2 i) (logand (* 3 i) #xFF)))
      (let* ((f1 (encode-frame +msg-key+ p1))
             (f2 (encode-frame +msg-frame+ p2))
             (buffer (cat-octets f1 f2)))
        (multiple-value-bind (type1 payload1 next1) (decode-frame buffer)
          (expect (= +msg-key+ type1))
          (expect (equalp p1 payload1))
          (expect (= (length f1) next1))
          (multiple-value-bind (type2 payload2 next2) (decode-frame buffer next1)
            (expect (= +msg-frame+ type2))
            (expect (equalp p2 payload2))
            (expect (= (+ (length f1) (length f2)) next2))
            (expect (= (length buffer) next2)))))))

  (it-property "encode-frame/decode-frame round-trips for any type byte and payload"
      ((type (gen-integer :min 0 :max 255))
       (payload-octets (gen-list (gen-integer :min 0 :max 255) :max-length 200)))
    (let* ((payload (to-octets payload-octets))
           (frame   (encode-frame type payload)))
      (multiple-value-bind (decoded-type decoded-payload next) (decode-frame frame)
        (expect (eql type decoded-type))
        (expect (equalp payload decoded-payload))
        (expect (= (length frame) next)))))

  (it-each ((0) (1) (255) (256) (65535))
      "u16-encode-decode-symmetric ~A"
      (n)
    (expect (= n (nerimux/protocol:read-u16 (nerimux/protocol:u16-octets n) 0))))

  (it-each ((0) (1) (65536) (#xFFFFFF) (#xFFFFFFFF))
      "u32-encode-decode-symmetric ~A"
      (n)
    (expect (= n (nerimux/protocol:read-u32 (nerimux/protocol:u32-octets n) 0))))

  (it-property "u16-octets/read-u16 round-trip across the full 16-bit range"
      ((n (gen-integer :min 0 :max 65535)))
    (expect (= n (nerimux/protocol:read-u16 (nerimux/protocol:u16-octets n) 0))))

  (it-property "u32-octets/read-u32 round-trip across the full 32-bit range"
      ((n (gen-integer :min 0 :max #xFFFFFFFF)))
    (expect (= n (nerimux/protocol:read-u32 (nerimux/protocol:u32-octets n) 0))))

  (it "u16-u32-encoders-produce-correct-byte-widths"
    (dolist (c (list (list 2 (nerimux/protocol:u16-octets 0)          "u16(0) = 2 bytes")
                     (list 2 (nerimux/protocol:u16-octets 65535)      "u16(max) = 2 bytes")
                     (list 4 (nerimux/protocol:u32-octets 0)          "u32(0) = 4 bytes")
                     (list 4 (nerimux/protocol:u32-octets #xFFFFFFFF) "u32(max) = 4 bytes")))
      (destructuring-bind (expected-len result desc) c
        (declare (ignore desc))
        (expect (= expected-len (length result))))))

  (it "msg-constructors-produce-correct-frames"
    (dolist (c (list (cons (msg-attach 24 80)                 +msg-attach+)
                      (cons (msg-key #(65))                   +msg-key+)
                      (cons (msg-resize 24 80)                +msg-resize+)
                      (cons (msg-detach)                      +msg-detach+)
                      (cons (msg-frame "hi")                  +msg-frame+)
                      (cons (msg-bye)                         +msg-bye+)
                      (cons (msg-reply "output")              +msg-reply+)
                      (cons (msg-command :new-window nil nil) +msg-command+)))
      (assert-decoded-frame-type (car c) (cdr c))))


  (it "msg-command-builds-valid-frame"
    (let ((frame (msg-command :new-window nil nil)))
      (multiple-value-bind (type payload next) (decode-frame frame)
        (expect (= +msg-command+ type))
        (expect (= (length frame) next))
        (multiple-value-bind (command target args)
            (decode-command-payload payload)
          (expect (eq :new-window command))
          (expect (null target))
          (expect (null args)))))
    (let ((frame (msg-command :send-keys "1:2.3" '("hello" "world"))))
      (multiple-value-bind (type payload) (decode-frame frame)
        (expect (= +msg-command+ type))
        (multiple-value-bind (command target args)
            (decode-command-payload payload)
          (expect (eq :send-keys command))
          (expect (string= "1:2.3" target))
          (expect (equal '("hello" "world") args))))))


  (it-each (((:new-window)                               :new-window  nil       nil           "no target/args")
            ((:select-pane :target "$1:0.0")             :select-pane "$1:0.0"  nil           "with target")
            ((:send-keys :args ("C-c" ""))               :send-keys   nil       ("C-c" "")    "with args")
            ((:resize-pane :target "2:0" :args ("-U" "5")) :resize-pane "2:0"  ("-U" "5")    "target+args")
            (("new-session" :target "$2")                :new-session "$2"      nil           "string command-name"))
      "encode-decode-command-payload: ~*~*~*~*~A"
      (encode-args expected-cmd expected-target expected-args desc)
    (declare (ignore desc))
    (multiple-value-bind (command target args)
        (decode-command-payload (apply #'encode-command-payload encode-args))
      (expect (eq expected-cmd command))
      (expect (equal expected-target target))
      (expect (equal expected-args args))))

  (it "decode-command-payload-command-name-with-colon-is-not-misidentified"
    (let* ((name-bytes (cl-codec-kit:string-to-octets "weird:name" :encoding :utf-8))
           (payload    (concatenate '(simple-array (unsigned-byte 8) (*))
                                    name-bytes #(0))))
      (multiple-value-bind (command target args) (decode-command-payload payload)
        (expect (stringp command))
        (expect (string= "weird:name" command))
        (expect (null target))
        (expect (null args)))))

  (it "decode-command-payload-unseen-command-name-does-not-intern-a-keyword"
    (let ((unseen-name "nerimux-test-unseen-command-9f3c2a"))
      (expect (null (find-symbol (string-upcase unseen-name) :keyword)))
      (let* ((name-bytes (cl-codec-kit:string-to-octets unseen-name :encoding :utf-8))
             (payload    (concatenate '(simple-array (unsigned-byte 8) (*))
                                      name-bytes #(0))))
        (decode-command-payload payload))
      (expect (null (find-symbol (string-upcase unseen-name) :keyword))))))

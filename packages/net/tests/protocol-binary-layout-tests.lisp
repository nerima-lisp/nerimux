(in-package #:nerimux/test/net)

(describe "protocol-suite"


  (it "message-type-tag-constants-have-expected-values"
    (dolist (c `((1 ,+msg-attach+  "+msg-attach+ must equal 1")
                 (2 ,+msg-key+     "+msg-key+ must equal 2")
                 (3 ,+msg-resize+  "+msg-resize+ must equal 3")
                 (4 ,+msg-detach+  "+msg-detach+ must equal 4")
                 (5 ,+msg-frame+   "+msg-frame+ must equal 5")
                 (6 ,+msg-bye+     "+msg-bye+ must equal 6")
                 (7 ,+msg-command+ "+msg-command+ must equal 7")
                 (8 ,+msg-reply+   "+msg-reply+ must equal 8")
                 (5 ,+header-size+ "+header-size+ must equal 5")))
      (destructuring-bind (expected constant desc) c
        (declare (ignore desc))
        (expect (= expected constant)))))


  (it "u16-octets-pair-max-values"
    (expect (equalp #(255 255 255 255)
                (nerimux/protocol:u16-octets-pair 65535 65535))))

  (it "u16-octets-pair-asymmetric-values"
    (let ((result (nerimux/protocol:u16-octets-pair 1 256)))
      (expect (= 4 (length result)))
      (expect (equalp #(0 1 1 0) result))))


  (it "u16-octets-table-driven-encoding"
    (dolist (entry '((0      #(0 0))
                     (1      #(0 1))
                     (127    #(0 127))
                     (128    #(0 128))
                     (255    #(0 255))
                     (256    #(1 0))
                     (512    #(2 0))
                     (32767  #(127 255))
                     (32768  #(128 0))
                     (65534  #(255 254))
                     (65535  #(255 255))))
      (destructuring-bind (n expected) entry
        (expect (equalp expected (nerimux/protocol:u16-octets n))))))

  (it "u32-octets-table-driven-encoding"
    (dolist (entry '((0          #(0 0 0 0))
                     (1          #(0 0 0 1))
                     (255        #(0 0 0 255))
                     (256        #(0 0 1 0))
                     (65535      #(0 0 255 255))
                     (65536      #(0 1 0 0))
                     (#xFFFFFF   #(0 255 255 255))
                     (#x01000000 #(1 0 0 0))
                     (#xFFFFFFFF #(255 255 255 255))))
      (destructuring-bind (n expected) entry
        (expect (equalp expected (nerimux/protocol:u32-octets n))))))


  (it "encode-frame-type-byte-is-first-byte"
    (dolist (entry (list (list +msg-attach+ (nerimux/protocol:u16-octets-pair 24 80))
                         (list +msg-key+    #(65 66))
                         (list +msg-detach+ #())))
      (destructuring-bind (type-tag payload) entry
        (let ((frame (encode-frame type-tag payload)))
          (expect (= type-tag (aref frame 0)))))))


  (it "decode-frame-zero-bytes-available-returns-nil"
    (let ((frame (msg-key #(1 2 3))))
      (multiple-value-bind (type payload next)
          (decode-frame frame 0 0)
        (expect (null type))
        (expect (null payload))
        (expect (= 0 next)))))


  (it "field-delimiter-constant-is-ascii-nul"
    (expect (= 0 nerimux/protocol:+field-delimiter+)))

  (it "frame-layout-offset-constants-are-consistent"
    (expect (= +header-size+
           (+ nerimux/protocol:+payload-length-offset+ 4)))
    (expect (= 2 nerimux/protocol:+cols-offset-in-size-payload+)))


  (it "decode-frame-with-nonzero-start-and-matching-end"
    (let* ((prefix  (make-array 5 :element-type '(unsigned-byte 8) :initial-element 0))
           (frame   (msg-detach))
           (buffer  (concatenate '(simple-array (unsigned-byte 8) (*)) prefix frame)))
      (multiple-value-bind (type payload next)
          (decode-frame buffer 5 (length buffer))
        (expect (= +msg-detach+ type))
        (expect (= 0 (length payload)))
        (expect (= (length buffer) next)))))

  (it "decode-frame-start-equals-end-returns-nil"
    (let ((frame (msg-resize 10 20)))
      (multiple-value-bind (type payload next)
          (decode-frame frame 3 3)
        (expect (null type))
        (expect (null payload))
        (expect (= 3 next)))))


  (it "msg-attach-max-u16-rows-cols-roundtrip"
    (multiple-value-bind (type payload)
        (decode-frame (msg-attach 65535 65535))
      (expect (= +msg-attach+ type))
      (multiple-value-bind (rows cols) (decode-size payload)
        (expect (= 65535 rows))
        (expect (= 65535 cols))))))

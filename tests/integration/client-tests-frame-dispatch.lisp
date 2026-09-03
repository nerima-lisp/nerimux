(in-package #:nerimux/test)

(describe "client-frame-dispatch-suite"


  (it "client-with-incoming-frame-msg-bye-dispatches"
    (with-guarded-socket-test
      (send-frame server-side (msg-bye))
      (let ((dispatched nil))
        (with-incoming-frame (type _payload client-side)
          ((null type)
           (setf dispatched :eof))
          ((= type +msg-bye+)
           (expect (zerop (length _payload)))
           (setf dispatched :bye))
          ((= type +msg-frame+)
           (setf dispatched :frame)))
        (expect (eq :bye dispatched)))))

  (it "client-with-incoming-frame-msg-frame-dispatches"
    (with-guarded-socket-test
      (send-frame server-side (msg-frame "hello"))
      (let ((received-text nil))
        (with-incoming-frame (type payload client-side)
          ((null type)         nil)
          ((= type +msg-bye+) nil)
          ((= type +msg-frame+)
           (setf received-text (decode-text payload))))
        (expect (string= "hello" received-text)))))

  (it "client-with-incoming-frame-multiple-frames-in-order"
    (with-guarded-socket-test
      (send-frame server-side (msg-frame "first"))
      (send-frame server-side (msg-frame "second"))
      (send-frame server-side (msg-bye))
      (let ((results '()))
        (dotimes (_ 3)
          (with-incoming-frame (type payload client-side)
            ((null type)        (push :eof results))
            ((= type +msg-bye+) (push :bye results))
            ((= type +msg-frame+)
             (push (decode-text payload) results))))
        (setf results (nreverse results))
        (expect (equal '("first" "second" :bye) results)))))

  (it "client-with-incoming-frame-unicode-content"
    (with-guarded-socket-test
      (send-frame server-side (msg-frame "日本語テスト"))
      (let ((received nil))
        (with-incoming-frame (type payload client-side)
          ((null type) nil)
          ((= type +msg-frame+)
           (setf received (decode-text payload))))
        (expect (string= "日本語テスト" received)))))


  (it "run-client-attach-frame-encoding"
    (let* ((frame   (msg-attach 24 80))
           (decoded (multiple-value-list (decode-frame frame))))
      (expect (= +msg-attach+ (first decoded)))
      (multiple-value-bind (rows cols)
          (decode-size (second decoded))
        (expect (= 24 rows))
        (expect (= 80 cols)))))


  (it "run-client-all-frame-types-encode-correctly"
    (let ((cases
           (list (list (msg-bye)                             +msg-bye+)
                 (list (msg-detach)                         +msg-detach+)
                 (list (msg-key (vector 65))                +msg-key+)
                 (list (msg-resize 30 100)                  +msg-resize+)
                 (list (msg-attach 24 80)                   +msg-attach+)
                 (list (msg-frame "text")                   +msg-frame+)
                 (list (msg-command "test-command" nil nil) +msg-command+))))
      (dolist (c cases)
        (destructuring-bind (frame expected-type) c
          (multiple-value-bind (got-type _payload) (decode-frame frame)
            (declare (ignore _payload))
            (expect (= expected-type got-type)))))))

  (it "client-with-incoming-frame-eof-dispatches"
    (with-temp-octet-file (path)
      (with-open-file (_out path :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede)
        (finish-output _out))
      (with-open-file (stream path :element-type '(unsigned-byte 8))
        (let ((dispatched nil))
          (with-incoming-frame (type _payload stream)
            ((null type)        (expect (null _payload))
                                (setf dispatched :eof))
            ((= type +msg-bye+) (setf dispatched :bye)))
          (expect (eq :eof dispatched)))))))

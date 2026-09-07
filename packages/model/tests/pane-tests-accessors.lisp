(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "pane-nil-slot-defaults"
    (let ((pane (make-no-pty-pane 1 0 0 20 5)))
      (expect (null (pane-window  pane)))
      (expect (null (pane-marked  pane)))))

  (it "pane-marked-settable"
    (let ((pane (make-no-pty-pane 1 0 0 20 5)))
      (setf (pane-marked pane) t)
      (expect (pane-marked pane) :to-be-truthy)))


  (it "pane-id-slot-accessible"
    (let ((pane (make-no-pty-pane 7 0 0 20 5)))
      (expect (= 7 (pane-id pane)))))

  (it "pane-x-y-width-height-accessible"
    (let ((pane (make-no-pty-pane 1 3 5 40 10)))
      (expect (= 3  (pane-x      pane)))
      (expect (= 5  (pane-y      pane)))
      (expect (= 40 (pane-width  pane)))
      (expect (= 10 (pane-height pane)))))

  (it "pane-no-pty-fd-and-pid-are-negative"
    (let ((pane (make-no-pty-pane 1 0 0 20 5)))
      (expect (= -1 (pane-fd  pane)))
      (expect (= -1 (pane-pid pane)))))

  (it "pane-screen-accessible"
    (let* ((screen (make-screen 20 5))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 20 :height 5
                              :fd -1 :pid -1 :screen screen)))
      (expect (eq screen (pane-screen pane)))))


  (it "pane-feed-empty-bytes-is-noop"
    (let* ((screen (make-screen 10 5))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                              :fd -1 :pid -1 :screen screen)))
      (finishes (pane-feed pane (make-array 0 :element-type '(unsigned-byte 8))))
      (expect (= 0 (screen-cursor-x screen)))
      (expect (= 0 (screen-cursor-y screen)))))


  (it "pane-feed-sets-dirty-flag"
    (let* ((screen (make-screen 10 5))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                              :fd -1 :pid -1 :screen screen)))
      (screen-clear-dirty screen)
      (pane-feed pane (cl-codec-kit:string-to-octets "A" :encoding :utf-8))
      (expect (nerimux/terminal/types:screen-dirty-p screen) :to-be-truthy)))


  (it "drain-response-queue-clears-queue-without-writing-when-no-pty"
    (let* ((screen (make-screen 10 5))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                              :fd -1 :pid -1 :screen screen)))
      (setf (nerimux/terminal/types:screen-response-queue screen)
            (list (format nil "~C[?1;2c" #\Escape)))
      (finishes (nerimux/pane::%drain-response-queue pane screen))
      (expect (null (nerimux/terminal/types:screen-response-queue screen)))))

  (it "pane-feed-records-raw-notification-and-text"
    (let* ((screen (make-screen 10 5))
           (pane (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                            :fd -1 :pid -1 :screen screen)))
      (pane-feed pane (make-array 9 :element-type '(unsigned-byte 8)
                                  :initial-contents
                                  '(27 93 57 59 104 105 7 65 66)))
      (let ((notifications (pane-drain-notifications pane)))
        (expect (= 1 (length notifications)))
        (expect (equalp #(27 93 57 59 104 105 7) (first notifications)))
        (expect (string= "hi" (pane-notification pane))))))

  (it "pane-feed-coalesces-one-hundred-notifications-in-one-second"
    (let* ((screen (make-screen 10 5))
           (pane (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                            :fd -1 :pid -1 :screen screen))
           (bytes (make-array (* 100 8)
                              :element-type '(unsigned-byte 8))))
      (loop for offset from 0 below (length bytes) by 8
            do (replace bytes #(27 93 57 59 120 120 120 7) :start1 offset))
      (pane-feed pane bytes)
      (expect (= 1 (length (pane-drain-notifications pane)))))))

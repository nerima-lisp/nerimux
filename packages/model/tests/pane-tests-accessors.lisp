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
      (expect (null (nerimux/terminal/types:screen-response-queue screen))))))

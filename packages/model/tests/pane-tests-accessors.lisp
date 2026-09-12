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

(describe "pane output preview"

  (it "drops a CSI sequence whole instead of leaving its parameter bytes"
    (let ((pane (make-pane :id 1 :screen (make-screen 20 5))))
      (nerimux/pane:pane-mark-output
       pane
       (coerce #(27 91 63 50 48 48 52 104 115 104 36 32 108 115)
               '(simple-array (unsigned-byte 8) (*))))
      (expect (string= "sh$ ls" (nerimux/pane:pane-last-output pane)))))

  (it "drops an OSC sequence ended by BEL and one ended by ST"
    (let ((pane (make-pane :id 2 :screen (make-screen 20 5))))
      (nerimux/pane:pane-mark-output
       pane
       (coerce #(27 93 48 59 116 105 116 108 101 7 111 27 93 50 59 120 27 92 107)
               '(simple-array (unsigned-byte 8) (*))))
      (expect (string= "ok" (nerimux/pane:pane-last-output pane)))))

  (it "folds carriage return and newline to spaces"
    (let ((pane (make-pane :id 3 :screen (make-screen 20 5))))
      (nerimux/pane:pane-mark-output
       pane
       (coerce #(97 13 10 98) '(simple-array (unsigned-byte 8) (*))))
      (expect (string= "a  b" (nerimux/pane:pane-last-output pane)))))

  (it "keeps only the last 256 characters of a long burst"
    (let ((pane (make-pane :id 4 :screen (make-screen 20 5)))
          (bytes (make-array 300 :element-type '(unsigned-byte 8)
                                 :initial-element 120)))
      (nerimux/pane:pane-mark-output pane bytes)
      (expect (= 256 (length (nerimux/pane:pane-last-output pane))))
      (expect (string= (make-string 256 :initial-element #\x)
                       (nerimux/pane:pane-last-output pane)))))

  (it "scans a chunk far longer than the preview length without truncating its escape handling"
    (let ((pane (make-pane :id 5 :screen (make-screen 20 5)))
          (bytes (make-array 70000 :element-type '(unsigned-byte 8)
                                   :initial-element 121)))
      (nerimux/pane:pane-mark-output pane bytes)
      (expect (= 256 (length (nerimux/pane:pane-last-output pane))))
      (expect (string= (make-string 256 :initial-element #\y)
                       (nerimux/pane:pane-last-output pane)))))

  (it "drops an unterminated OSC sequence that starts long before the tail of a large chunk"
    ;; The former bounded lookback window searched for a preceding escape only
    ;; within one window's width, so an OSC beginning more than a window
    ;; before the scan point was invisible to that search and the scan
    ;; resumed inside the sequence's own body, printing its parameter bytes
    ;; as text (S1). Scanning the whole chunk from index 0 recognises the OSC
    ;; from its start and drops it whole regardless of how long it runs.
    (let ((pane (make-pane :id 6 :screen (make-screen 20 5)))
          (bytes (make-array 20000 :element-type '(unsigned-byte 8)
                                   :initial-element 120)))
      (setf (aref bytes 100) 27
            (aref bytes 101) 93)
      (fill bytes 48 :start 102)
      (nerimux/pane:pane-mark-output pane bytes)
      (expect (string= (make-string 100 :initial-element #\x)
                       (nerimux/pane:pane-last-output pane))))))

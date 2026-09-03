(in-package #:nerimux/test)

(describe "pane-response-queue-pty-suite"

  (it "drain-response-queue-writes-queued-reply-to-real-fd"
    (let ((nerimux/ports:*write-pty* #'nerimux/pty:pty-write))
      (with-pipe-fds (read-fd write-fd)
        (let* ((screen (make-screen 10 5))
               (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                                  :fd write-fd :pid -1 :screen screen))
               (reply  (format nil "~C[?1;2c" #\Escape)))
          (setf (nerimux/terminal/types:screen-response-queue screen) (list reply))
          (nerimux/pane::%drain-response-queue pane screen)
          (expect (null (nerimux/terminal/types:screen-response-queue screen)))
          (expect (equalp (cl-codec-kit:string-to-octets reply :encoding :utf-8)
                          (pty-read-blocking-into read-fd (make-array 32 :element-type '(unsigned-byte 8)))))))))
)

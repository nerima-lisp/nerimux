(in-package #:nerimux/test)

;;;; Pane response-queue drain, through the real PTY port.
;;;;
;;;; Moved out of packages/model/tests/pane-tests-accessors.lisp when
;;;; domain/model became nerimux-model. The production path goes through
;;;; nerimux/ports, which is why nerimux-model does not depend on nerimux-pty --
;;;; but this case installs the real pty adapter into *write-pty* and reads the
;;;; bytes back with pty-read-blocking-into, so it exercises both units at once
;;;; and belongs to neither.
(describe "pane-response-queue-pty-suite"

  ;; %drain-response-queue's write-back branch (pane-fd > 0) was previously only
  ;; reachable with a synthetic :fd -1 pane, so the actual write-pty call was
  ;; never exercised. A real pipe fd stands in for a PTY master fd here.
  ;;
  ;; *write-pty* is nil outside a running server (install-pty-port only runs at
  ;; server startup); bind it to the real pty-write for this test's extent so
  ;; write-pty's (funcall *write-pty* ...) has something to call instead of
  ;; signalling undefined-function on nil.
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

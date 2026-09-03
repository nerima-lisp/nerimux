(in-package #:nerimux/test)

(describe "runtime-suite"


  (it "wait-for-channel-returns-on-signal"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal))
          (channel-name "wfc-test"))
      (nerimux::%ensure-channel channel-name)
      (cl-concurrent-kit:make-thread
       (lambda ()
         (sleep 0.05)
         (nerimux::signal-channel channel-name))
       :name "wfc-signal-thread")
      (finishes (nerimux::wait-for-channel channel-name)
                "wait-for-channel must return after signal")))

  (it "wait-for-channel-times-out"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (with-stubbed-fdefinition
          ((nerimux::condition-wait
            (lambda (cv lock &key timeout)
              (declare (ignore cv lock timeout))
              nil)))
        (expect (null (nerimux::wait-for-channel "timeout-ch"))))))


  (it "reader-eof-state-marks-pane-dead-and-stops"
    (let ((nerimux/ports:*close-pty* (lambda (fd pid)
                                      (declare (ignore fd pid))
                                      nil))
          (pane (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 5 3))))
      (expect (null (nerimux::reader-eof-state pane)))
      (expect (= -1 (pane-fd pane)))
      (expect (= -1 (pane-pid pane)))))


  (it "install-sigwinch-handler-sets-dirty-and-resize"
    (let ((nerimux::*dirty* nil)
          (nerimux::*resize-pending* nil))
      (finishes (nerimux::install-sigwinch-handler)
                "install-sigwinch-handler must not signal"))))

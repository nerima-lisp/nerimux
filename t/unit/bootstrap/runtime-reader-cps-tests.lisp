(in-package #:nerimux/test)

;;;; reader CPS state machine contracts

(describe "runtime-suite"

  ;; All CPS reader state machine functions are defined.  R2.6 removed the
  ;; remain-on-exit parking state (#'reader-remain-on-exit-state) along with
  ;; the option that used to select it, so idle/reading/eof are the complete
  ;; state set now.
  (it "reader-state-functions-are-all-fbound"
    (dolist (sym '(nerimux::reader-idle-state
                   nerimux::reader-reading-state
                   nerimux::reader-eof-state
                   nerimux::%run-reader-states
                   nerimux::start-reader-thread
                   nerimux::install-sigwinch-handler))
      (expect (fboundp sym))))

  (it "reader-idle-state-follows-pty-readiness"
    (let ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3)))
          (calls 0))
      (with-stubbed-fdefinition
          ((nerimux/pty:select-fds
            (lambda (fds timeout-us)
              (declare (ignore timeout-us))
              (incf calls)
              (when (= 7 (first fds)) fds))))
        (expect (eq #'nerimux::reader-reading-state
                    (nerimux::reader-idle-state pane)))
        (setf (pane-fd pane) -1)
        (expect (eq #'nerimux::reader-idle-state
                    (nerimux::reader-idle-state pane))))
      (expect (= 2 calls))))

  (it "reader-reading-state-handles-empty-and-nonempty-pty-reads"
    (let ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3)))
          (payloads (list #(65) #(65 7) nil))
          (fed nil)
          (outputs nil)
          (bells 0)
          (dirty 0))
      (let ((nerimux::*reader-scratch-buffer* (make-array 16
                                                           :element-type '(unsigned-byte 8))))
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-read-blocking-into
              (lambda (fd buffer)
                (declare (ignore fd buffer))
                (pop payloads)))
             (nerimux/model:pane-feed
              (lambda (received-pane bytes)
                (declare (ignore received-pane))
                (push bytes fed)))
             (nerimux/model:pane-mark-output
              (lambda (received-pane bytes)
                (declare (ignore received-pane))
                (push bytes outputs)))
             (nerimux/model:pane-mark-bell
              (lambda (received-pane)
                (declare (ignore received-pane))
                (incf bells)))
             (nerimux::%mark-dirty
              (lambda ()
                (incf dirty))))
          (expect (eq #'nerimux::reader-idle-state
                      (nerimux::reader-reading-state pane)))
          (expect (eq #'nerimux::reader-idle-state
                      (nerimux::reader-reading-state pane)))
          (expect (eq #'nerimux::reader-eof-state
                      (nerimux::reader-reading-state pane))))
        (expect (= 2 (length fed)))
        (expect (= 2 (length outputs)))
        (expect (= 1 bells))
        (expect (= 2 dirty)))))

  (it "run-reader-states-executes-the-current-state-before-stopping"
    (with-dead-pane (pane)
      (let ((calls 0)
            (nerimux::*running* t))
        (nerimux::%run-reader-states
         pane
         (lambda (received-pane)
           (declare (ignore received-pane))
           (incf calls)
           (setf nerimux::*running* nil)
           nil))
        (expect (= 1 calls)))))

  (it "start-reader-thread-installs-a-reader-loop"
    (with-dead-pane (pane)
      (let ((reader-function nil)
            (nerimux::*running* nil))
        (with-stubbed-fdefinition
            ((cl-concurrent-kit:make-thread
              (lambda (function &rest arguments)
                (declare (ignore arguments))
                (setf reader-function function)
                :reader-thread)))
          (expect (eq :reader-thread
                      (nerimux::start-reader-thread pane)))
          (expect (functionp reader-function))
          (finishes (funcall reader-function))))))

  ;; %run-reader-states exits immediately when *running* is NIL, even
  ;; given a non-NIL initial state (loop while *running*).
  (it "run-reader-states-exits-when-running-nil"
    (with-dead-pane (pane)
      (let* ((nerimux::*running* nil)
             (boom (lambda (_p)
                     (declare (ignore _p))
                     (error "state function called despite *running*=NIL"))))
        (finishes (nerimux::%run-reader-states pane boom)
                  "%run-reader-states must exit immediately when *running* is NIL")))))

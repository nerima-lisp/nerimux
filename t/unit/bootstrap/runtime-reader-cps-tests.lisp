(in-package #:nerimux/test)

;;;; reader CPS state machine contracts

(describe "runtime-suite"

  ;; reader-remain-on-exit-state returns NIL immediately when *running* is NIL.
  (it "reader-remain-on-exit-state-returns-nil-when-not-running"
    (with-dead-pane (pane)
      (let ((nerimux::*running* nil))
        (expect (null (nerimux::reader-remain-on-exit-state pane))))))

  ;; All CPS reader state machine functions are defined.
  (it "reader-state-functions-are-all-fbound"
    (dolist (sym '(nerimux::reader-idle-state
                   nerimux::reader-reading-state
                   nerimux::reader-remain-on-exit-state
                   nerimux::reader-eof-state
                   nerimux::%run-reader-states
                   nerimux::start-reader-thread
                   nerimux::install-sigwinch-handler
                   nerimux::start-status-timer))
      (expect (fboundp sym))))

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

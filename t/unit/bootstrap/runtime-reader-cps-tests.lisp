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

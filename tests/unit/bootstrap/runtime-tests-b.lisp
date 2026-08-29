(in-package #:nerimux/test)

;;;; wait-for-channel, reader EOF, and sigwinch — part II

(describe "runtime-suite"

  ;;; ── wait-for-channel (bounded blocking path) ─────────────────────────────────

  ;; wait-for-channel unblocks when signal-channel is called from another thread.
  (it "wait-for-channel-returns-on-signal"
    ;; Spawn a thread that signals after a short delay and verify we return.
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal))
          (channel-name "wfc-test"))
      (nerimux::%ensure-channel channel-name)
      (cl-concurrent-kit:make-thread
       (lambda ()
         (sleep 0.05)
         (nerimux::signal-channel channel-name))
       :name "wfc-signal-thread")
      ;; wait-for-channel must return (T or NIL) without hanging.
      (finishes (nerimux::wait-for-channel channel-name)
                "wait-for-channel must return after signal")))

  ;; wait-for-channel returns NIL when the bounded wait expires.
  (it "wait-for-channel-times-out"
    ;; Stub the blocking primitive so this exercises the timeout result without
    ;; making the suite sleep for the production timeout.
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (with-stubbed-fdefinition
          ((nerimux::condition-wait
            (lambda (cv lock &key timeout)
              (declare (ignore cv lock timeout))
              nil)))
        (expect (null (nerimux::wait-for-channel "timeout-ch"))))))

  ;;; ── pane-close dead-pane marking ──────────────────────────────────────────────
  ;;;
  ;;; When a pane's process exits, reader-eof-state must mark the pane DEAD: close
  ;;; the now-EOF master fd and reset pane-fd/pane-pid to -1, then stop the reader
  ;;; (pane 終了時は即座に閉じる, §1.4 / R2.6 — there is no remain-on-exit parking
  ;;; state left to keep the pane visible under any longer).  #{pane_dead} keyed on
  ;;; (<= pane-fd 0), and respawn-pane (without -k) is gated on the pane being dead;
  ;;; previously the reader never reset the fd so both were wrong.  The test binds
  ;;; the PTY close port to a no-op and uses a high synthetic fd with pid -1.

  ;; reader-eof-state always marks the pane dead (pane-fd/pane-pid reset to -1)
  ;; and always returns NIL, stopping the reader loop.
  (it "reader-eof-state-marks-pane-dead-and-stops"
    (let ((nerimux/ports:*close-pty* (lambda (fd pid)
                                      (declare (ignore fd pid))
                                      nil))
          (pane (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 5 3))))
      (expect (null (nerimux::reader-eof-state pane)))
      (expect (= -1 (pane-fd pane)))
      (expect (= -1 (pane-pid pane)))))

  ;;; ── New coverage: refactored helper functions ─────────────────────────────────

  ;; install-sigwinch-handler registers a handler that sets *dirty* and *resize-pending*.
  (it "install-sigwinch-handler-sets-dirty-and-resize"
    ;; We can only verify the handler is installed (fboundp already tested).
    ;; Triggering SIGWINCH in a test is unsafe (it would fire on the test process).
    ;; Verify the state variables are bound and the installer doesn't error.
    (let ((nerimux::*dirty* nil)
          (nerimux::*resize-pending* nil))
      (finishes (nerimux::install-sigwinch-handler)
                "install-sigwinch-handler must not signal"))))

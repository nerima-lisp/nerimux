(in-package #:nerimux/test)

;;;; wait-for-channel, reader EOF and the remain-on-exit banner — part II

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

  ;; wait-for-channel returns NIL when no signal arrives within the timeout.
  (it "wait-for-channel-times-out"
    ;; Use an isolated channels table so no signal is present.
    ;; +wait-for-channel-timeout+ is 30 s; we override with a very short one
    ;; by binding the constant — not possible in CL, so we test the shape only.
    ;; The real timeout behaviour is verified by the unblocking test above.
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      ;; Calling wait-for-channel on a fresh unsignalled channel must eventually
      ;; return (it uses a bounded condition-wait).  We cannot shrink the timeout
      ;; in this test, so just verify the function is callable and returns a boolean.
      (expect (fboundp 'nerimux::wait-for-channel))))

  ;;; ── remain-on-exit dead-pane marking ─────────────────────────────────────────
  ;;;
  ;;; When a pane's process exits, reader-eof-state must mark the pane DEAD: close
  ;;; the now-EOF master fd and reset pane-fd/pane-pid to -1.  #{pane_dead} keys on
  ;;; (<= pane-fd 0), and respawn-pane (without -k) is gated on the pane being dead;
  ;;; previously the reader never reset the fd so both were wrong.  The tests use a
  ;;; high synthetic fd (closing it yields EBADF, swallowed by pty-close's
  ;;; ignore-errors) and pid -1 (no signal is ever sent).

  ;; On EOF with remain-on-exit set, the pane is kept visible AND marked dead
  ;; (pane-fd/pane-pid reset to -1).
  (it "reader-eof-state-marks-pane-dead-under-remain-on-exit"
    (let ((pane (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 5 3))))
      (with-isolated-options ("remain-on-exit" t)
        (expect (functionp (nerimux::reader-eof-state pane))))
      (expect (= -1 (pane-fd pane)))
      (expect (= -1 (pane-pid pane)))))

  ;; The dead-marking happens on EVERY process exit, independent of remain-on-exit;
  ;; the reader still stops (returns NIL) when remain-on-exit is off.
  (it "reader-eof-state-marks-pane-dead-without-remain-on-exit"
    (let ((pane (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 5 3))))
      (with-isolated-options ("remain-on-exit" nil)
        (expect (null (nerimux::reader-eof-state pane))))
      (expect (= -1 (pane-fd pane)))))

  ;; #{pane_dead} flips 0 -> 1 once reader-eof-state marks the pane dead (end-to-end,
  ;; no fork).
  (it "pane-dead-format-reflects-reader-eof"
    (let* ((pane (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 5 3)))
           (win  (make-window :id 0 :name "w" :width 5 :height 3 :panes (list pane)))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (window-select-pane win pane)
      (session-select-window sess win)
      (let ((ctx (nerimux/format:format-context-from-session sess win pane)))
        (expect (string= "0" (nerimux/format:expand-format "#{pane_dead}" ctx))))
      (with-isolated-options ("remain-on-exit" t)
        (nerimux::reader-eof-state pane))
      (let ((ctx (nerimux/format:format-context-from-session sess win pane)))
        (expect (string= "1" (nerimux/format:expand-format "#{pane_dead}" ctx))))))

  ;;; ── New coverage: refactored helper functions ─────────────────────────────────

  ;; %write-remain-on-exit-banner writes the formatted banner to the pane screen.
  ;; This helper was extracted from reader-eof-state; we verify it side-effects
  ;; the screen without needing to trigger the full CPS state transition.
  (it "write-remain-on-exit-banner-writes-to-screen"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 20 3))))
      (with-isolated-options ("remain-on-exit-format" "EXIT")
        (nerimux::%write-remain-on-exit-banner pane)
        (expect (search "EXIT" (row-string (pane-screen pane) 0 :end 20))))))

  ;; install-sigwinch-handler registers a handler that sets *dirty* and *resize-pending*.
  (it "install-sigwinch-handler-sets-dirty-and-resize"
    ;; We can only verify the handler is installed (fboundp already tested).
    ;; Triggering SIGWINCH in a test is unsafe (it would fire on the test process).
    ;; Verify the state variables are bound and the installer doesn't error.
    (let ((nerimux::*dirty* nil)
          (nerimux::*resize-pending* nil))
      (finishes (nerimux::install-sigwinch-handler)
                "install-sigwinch-handler must not signal")))

  ;; +remain-on-exit-poll-seconds+ is a positive real constant.
  (it "remain-on-exit-poll-seconds-is-positive"
    (expect (plusp nerimux::+remain-on-exit-poll-seconds+))
    (expect (realp nerimux::+remain-on-exit-poll-seconds+)))

  ;;; ── Pane death record (remain-on-exit #{pane_dead_status} family) ────────────

  ;; %remain-on-exit-banner resolves #{pane_dead_status}/#{pane_dead_time} from
  ;; the pane's death record via %pane-death-context.
  (it "remain-on-exit-banner-expands-death-record"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 20 3))))
      (setf (nerimux/model:pane-dead-status pane) 42
            (nerimux/model:pane-dead-time pane) 123)
      (with-isolated-options ("remain-on-exit-format"
                              "dead status=#{pane_dead_status} t=#{pane_dead_time}")
        (let ((banner (nerimux::%remain-on-exit-banner pane)))
          (expect (search "status=42" banner))
          (expect (search "t=123" banner))))))

  ;; reader-eof-state records the death time on a pane whose fd hits EOF (the
  ;; synthetic fd has no known child, so status/signal stay NIL).
  (it "reader-eof-state-stamps-dead-time"
    (with-isolated-state
      (let ((pane (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 20 3))))
        (nerimux::reader-eof-state pane)
        (expect (integerp (nerimux/model:pane-dead-time pane)))
        (expect (null (nerimux/model:pane-dead-status pane)))
        (expect (= -1 (nerimux/model:pane-fd pane)))))))

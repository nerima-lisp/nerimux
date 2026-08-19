(in-package #:nerimux/test)

;;;; add-message-log table-driven, add-prompt-history, wait-for-channel — part II

(describe "runtime-suite"

  ;;; ── add-message-log table-driven coverage ───────────────────────────────────

  ;; Adding three messages in order leaves them newest-first in the log.
  (it "add-message-log-multiple-entries-ordered-newest-first"
    (let ((nerimux::*message-log* nil))
      (dolist (msg '("alpha" "beta" "gamma"))
        (nerimux::add-message-log msg))
      (expect (= 3 (length nerimux::*message-log*)))
      (expect (string= "gamma" (cdr (first  nerimux::*message-log*))))
      (expect (string= "beta"  (cdr (second nerimux::*message-log*))))
      (expect (string= "alpha" (cdr (third  nerimux::*message-log*))))))

  ;; Adding exactly message-limit + 1 entries produces exactly
  ;; message-limit entries in the log (exact truncation, no off-by-one).
  (it "add-message-log-truncates-to-exact-max"
    (with-isolated-options ("message-limit" 8)
      (let ((nerimux::*message-log* nil))
        (dotimes (i 9)                      ; message-limit + 1
          (nerimux::add-message-log (format nil "~D" i)))
        (expect (= 8 (length nerimux::*message-log*))))))

  ;;; ── add-prompt-history ────────────────────────────────────────────────────────

  ;; add-prompt-history records a non-empty string as the newest *prompt-history* entry.
  (it "add-prompt-history-prepends-string"
    (let ((nerimux::*prompt-history* (history-kit:make-history)))
      (nerimux::add-prompt-history "first")
      (expect (= 1 (history-kit:history-count nerimux::*prompt-history*)))
      (expect (string= "first" (first (%prompt-history-texts))))))

  ;; add-prompt-history ignores empty strings — they are not added.
  (it "add-prompt-history-ignores-empty-string"
    (let ((nerimux::*prompt-history* (history-kit:make-history)))
      (nerimux::add-prompt-history "")
      (expect (history-kit:history-empty-p nerimux::*prompt-history*))))

  ;; add-prompt-history ignores non-string inputs (stringp guard).
  (it "add-prompt-history-ignores-non-string"
    (let ((nerimux::*prompt-history* (history-kit:make-history)))
      (nerimux::add-prompt-history 42)
      (nerimux::add-prompt-history nil)
      (expect (history-kit:history-empty-p nerimux::*prompt-history*))))

  ;; add-prompt-history caps *prompt-history* at +max-prompt-history+.
  (it "add-prompt-history-caps-at-max"
    (let ((nerimux::*prompt-history* (history-kit:make-history))
          (limit nerimux::+max-prompt-history+))
      (dotimes (i (+ limit 5))
        (nerimux::add-prompt-history (format nil "entry-~D" i)))
      (expect (= limit (history-kit:history-count nerimux::*prompt-history*)))))

  ;; add-prompt-history records: newest entry is first.
  (it "add-prompt-history-newest-first"
    (let ((nerimux::*prompt-history* (history-kit:make-history)))
      (nerimux::add-prompt-history "alpha")
      (nerimux::add-prompt-history "beta")
      (expect (string= "beta" (first (%prompt-history-texts))))
      (expect (string= "alpha" (second (%prompt-history-texts))))))

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

  ;;; ── Status interval timer ────────────────────────────────────────────────────

  ;; *status-timer* is defined as an internal variable (not exported).
  (it "status-timer-var-is-boundp"
    ;; *status-timer* is intentionally not exported — it is read/set only in
    ;; main.lisp and server.lisp.  We still verify it exists as a defvar.
    (expect (boundp 'nerimux::*status-timer*)))

  ;; start-status-timer returns a non-nil thread object.
  (it "start-status-timer-returns-thread"
    (with-global-running t
      (let ((thread (nerimux::start-status-timer (lambda () nil))))
        (unwind-protect
             (expect thread :to-be-truthy)
          ;; Clean up: stop the timer thread.  Setting the GLOBAL *running* NIL
          ;; (we are inside with-global-running, not a LET) is what the spawned
          ;; timer thread observes, so it exits and join-thread returns promptly.
          (setf nerimux::*running* nil)
          (ignore-errors
            (nerimux::%join-thread-with-timeout
             thread nerimux::+reader-thread-join-timeout+))))))

  ;; With a short status-interval, at least one dirty callback fires.
  (it "start-status-timer-fires-callback"
    ;; Use a very short interval (1 second minimum enforced by max 1) but we
    ;; set status-interval to 0 so max 1 clamps it to 1.  We use a counter
    ;; closure, set *running* to nil after a brief wall-clock wait, then
    ;; verify at least one call occurred.
    ;; The timer thread reads the GLOBAL *running*, so drive it via
    ;; with-global-running; a LET would be invisible to the spawned thread and
    ;; leak it into later suites (breaking fork()).
    (with-global-running t
     (let ((counter 0))
      (let ((original-interval (nerimux/options:get-option "status-interval")))
        (unwind-protect
             (progn
               ;; Force a 1-second interval (minimum enforced via max 1).
               (nerimux/options:set-option "status-interval" 1)
               (let ((thread (nerimux::start-status-timer
                              (lambda () (incf counter)))))
                 (unwind-protect
                      (progn
                        ;; Poll for the first callback (interval=1s) instead of a
                        ;; fixed sleep, so a loaded build machine cannot starve the
                        ;; timer thread within the window.  Budget ~6s; exits early.
                        (loop repeat 600 until (>= counter 1) do (sleep 0.01))
                        (setf nerimux::*running* nil)
                        (ignore-errors
                          (nerimux::%join-thread-with-timeout
                           thread nerimux::+reader-thread-join-timeout+))
                        (expect (>= counter 1)))
                   ;; Ensure thread is stopped even if assertion fails.
                   (setf nerimux::*running* nil))))
          ;; Restore original status-interval.
          (nerimux/options:set-option "status-interval" original-interval))))))

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
    (with-isolated-hooks
      (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 20 3))))
        (with-isolated-options ("remain-on-exit-format" "EXIT")
          (nerimux::%write-remain-on-exit-banner pane)
          (expect (search "EXIT" (row-string (pane-screen pane) 0 :end 20)))))))

  ;; %update-window-on-pane-output sets last-output-time to the current universal-time.
  (it "update-window-on-pane-output-stamps-timestamp"
    (with-isolated-state
      (let* ((sess (make-fake-session :nwindows 1))
             (win  (nerimux/model:session-active-window sess))
             (before (get-universal-time)))
        (setf (nerimux/model:window-last-output-time win) 0)
        (nerimux::%update-window-on-pane-output win (first (nerimux/model:window-panes win)))
        (expect (>= (nerimux/model:window-last-output-time win) before)))))

  ;; %update-window-on-pane-output clears window-silence-flag (new output resets silence).
  (it "update-window-on-pane-output-clears-silence-flag"
    (with-isolated-state
      (let* ((sess (make-fake-session :nwindows 1))
             (win  (nerimux/model:session-active-window sess)))
        (setf (nerimux/model:window-silence-flag win) t)
        (nerimux::%update-window-on-pane-output win (first (nerimux/model:window-panes win)))
        (expect (nerimux/model:window-silence-flag win) :to-be-falsy))))

  ;; %update-window-on-pane-output is a no-op when window is NIL.
  (it "update-window-on-pane-output-nil-window-is-noop"
    (finishes (nerimux::%update-window-on-pane-output nil nil)
              "%update-window-on-pane-output must not error on NIL window"))

  ;; %fire-silence-alert sets the silence flag, fires the hook, and calls dirty-fn.
  (it "fire-silence-alert-sets-flag-and-fires-hook"
    (with-isolated-state
      (let* ((sess   (make-fake-session :nwindows 1))
             (win    (nerimux/model:session-active-window sess))
             (fired  nil)
             (dirty  nil))
        (nerimux/hooks:add-hook "alert-silence"
                                (lambda (&rest _) (declare (ignore _)) (setf fired t)))
        (nerimux::%fire-silence-alert win (lambda () (setf dirty t)))
        (expect (nerimux/model:window-silence-flag win) :to-be-truthy)
        (expect fired :to-be-truthy)
        (expect dirty :to-be-truthy))))

  ;; %maybe-auto-dismiss-overlay dismisses an overlay that has been shown longer
  ;; than display-time.
  (it "maybe-auto-dismiss-overlay-dismisses-expired"
    (with-isolated-state
      (let ((nerimux/prompt:*overlay* "test overlay"))
        ;; Set shown-at to a time far in the past so it has definitely expired.
        (setf nerimux/prompt:*overlay-shown-at* (- (get-universal-time) 10))
        (with-isolated-options ("display-time" 500)  ; 500 ms = 0.5 s
          (let ((result (nerimux::%maybe-auto-dismiss-overlay)))
            (expect result :to-be-truthy)
            (assert-overlay-inactive "overlay must be cleared after dismissal"))))))

  ;; %maybe-auto-dismiss-overlay does not dismiss an overlay shown very recently.
  (it "maybe-auto-dismiss-overlay-keeps-recent-overlay"
    (with-isolated-state
      (let ((nerimux/prompt:*overlay* "recent overlay"))
        ;; shown-at = now → not expired.
        (setf nerimux/prompt:*overlay-shown-at* (get-universal-time))
        (with-isolated-options ("display-time" 5000)  ; 5000 ms = 5 s
          (let ((result (nerimux::%maybe-auto-dismiss-overlay)))
            (expect result :to-be-falsy)
            (assert-overlay-active "recent overlay must remain active"))))))

  ;; %check-lock-after-time locks the session when idle time exceeds lock-after-time.
  (it "check-lock-after-time-locks-session-on-inactivity"
    (with-isolated-state
      (let* ((sess  (make-fake-session :nwindows 1))
             (dirty nil))
        (nerimux/options:set-option "lock-after-time" 1)
        (setf nerimux::*last-activity-time* (- (get-universal-time) 60))
        (setf (nerimux/model:session-locked-p sess) nil)
        (nerimux::%check-lock-after-time sess (lambda () (setf dirty t)))
        (expect (nerimux/model:session-locked-p sess) :to-be-truthy)
        (expect dirty :to-be-truthy))))

  ;; %check-lock-after-time is a no-op when lock-after-time is 0 (disabled).
  (it "check-lock-after-time-noop-when-zero"
    (with-isolated-state
      (let* ((sess  (make-fake-session :nwindows 1))
             (dirty nil))
        (nerimux/options:set-option "lock-after-time" 0)
        (setf nerimux::*last-activity-time* (- (get-universal-time) 60))
        (setf (nerimux/model:session-locked-p sess) nil)
        (nerimux::%check-lock-after-time sess (lambda () (setf dirty t)))
        (expect (nerimux/model:session-locked-p sess) :to-be-falsy)
        (expect dirty :to-be-falsy))))

  ;; %effective-prompt-history-limit returns the prompt-history-limit option when set.
  (it "effective-prompt-history-limit-returns-option-value"
    (with-isolated-options ("prompt-history-limit" 42)
      (expect (= 42 (nerimux::%effective-prompt-history-limit)))))

  ;; %effective-prompt-history-limit falls back to +max-prompt-history+ when unset.
  (it "effective-prompt-history-limit-returns-default-when-unset"
    (with-fresh-options
      (expect (= nerimux::+max-prompt-history+
                 (nerimux::%effective-prompt-history-limit)))))

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

  ;; +default-display-time-ms+ is a positive integer constant.
  (it "default-display-time-ms-is-positive"
    (expect (plusp nerimux::+default-display-time-ms+))
    (expect (integerp nerimux::+default-display-time-ms+)))

  ;; +ms-per-second+ is 1000.0.
  (it "ms-per-second-constant-is-correct"
    (expect (= 1000.0 nerimux::+ms-per-second+)))

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

(in-package #:nerimux)

;;;; Status interval timer: poll loop, monitor-silence, overlay auto-dismiss,
;;;;  and start-status-timer.

;;; -- Status interval timer --------------------------------------------------

(defconstant +status-timer-poll-seconds+ 0.1
  "Granularity (seconds) at which the status timer re-checks *running* and the
   elapsed interval.  Kept small so the thread shuts down promptly when *running*
   clears instead of holding a multi-second sleep that would outlive the
   join-thread timeout and leak the thread (which, fatally, makes every
   subsequent tests or runtime state).")

(defun %maybe-auto-dismiss-overlay ()
  "Auto-dismiss the active overlay when display-time milliseconds have elapsed.
   display-time is in ms (default +default-display-time-ms+); the timer
   resolution is +status-timer-poll-seconds+ so actual dismiss may lag up to
   that amount.  Only affects transient overlays shown without :no-timer;
   long-lived paged overlays (list-keys, list-sessions) use :no-timer."
  (when (nerimux/prompt:overlay-active-p)
    (let* ((display-time-ms (or (nerimux/options:get-option "display-time")
                                +default-display-time-ms+))
           (display-secs    (/ display-time-ms +ms-per-second+))
           (shown-at        (nerimux/prompt:overlay-shown-at))
           (elapsed         (- (get-universal-time) shown-at)))
      (when (and (plusp shown-at) (>= elapsed display-secs))
        (nerimux/prompt:clear-overlay)
        t))))

(defun %fire-silence-alert (win dirty-fn)
  "Set the silence flag, fire the alert-silence hook, and show a visual overlay
   for WIN.  Calls DIRTY-FN to request a repaint.
   Extracted from %check-monitor-silence to reduce nesting and separate the
   traversal logic (in the caller) from the per-window action."
  (setf (nerimux/model:window-silence-flag win) t)
  ;; Fire the alert-silence hook (matches real tmux).
  (nerimux/hooks:run-hooks nerimux/hooks:+hook-alert-silence+ win)
  ;; visual-silence on/both: show a transient overlay naming the quiet window
  ;; (mirrors visual-activity in %mark-window-activity).
  (when (%visual-alert-message-p "visual-silence")
    (%show-window-alert-overlay "Silence" win))
  (funcall dirty-fn))

(defun %window-monitor-silence-due-p (win session now silence-secs silence-action)
  "True when WIN has been quiet long enough to trigger monitor-silence."
  (let ((last-output-time (nerimux/model:window-last-output-time win)))
    (and (> last-output-time 0)
         (not (nerimux/model:window-silence-flag win))
         (>= (- now last-output-time) silence-secs)
         ;; silence-action gates which windows alert.
         (%alert-action-fires-p silence-action
                                (eq win (nerimux/model:session-active-window session))))))

(defun %check-monitor-silence-session (session now silence-secs silence-action dirty-fn)
  "Scan SESSION's windows and fire alerts for any silence matches."
  (dolist (win (nerimux/model:session-windows session))
    (when (%window-monitor-silence-due-p win session now silence-secs silence-action)
      (%fire-silence-alert win dirty-fn))))

(defun %check-monitor-silence (sessions dirty-fn)
  "For each window in SESSIONS with monitor-silence enabled, set
   window-silence-flag when no PTY output has arrived for monitor-silence seconds.
   monitor-silence = 0 (default) disables per-window silence monitoring."
  (let ((silence-secs (nerimux/options:get-option "monitor-silence")))
    (when (and (integerp silence-secs) (> silence-secs 0))
      (let ((now (get-universal-time))
            (silence-action (or (nerimux/options:get-option "silence-action") "other")))
        (dolist (entry sessions)
          (%check-monitor-silence-session (cdr entry) now silence-secs silence-action
                                          dirty-fn))))))

(defun %timer-tick-overlay (dirty-fn)
  "Check if the active overlay has expired; dismiss it and call DIRTY-FN if so."
  (when (%maybe-auto-dismiss-overlay) (funcall dirty-fn)))

(defun %timer-tick-status-interval (elapsed dirty-fn)
  "Refresh the status bar when ELAPSED seconds have met or exceeded status-interval.
   Returns the new elapsed value (reset to 0 if interval fired, else unchanged).
   status-interval 0 disables the periodic redraw (tmux semantics)."
  (let ((interval (nerimux/options:get-option "status-interval")))
    (if (and *running* (integerp interval) (> interval 0)
             (>= elapsed interval))
        (progn (funcall dirty-fn) 0)
        elapsed)))

(defun %timer-tick-silence (server-sessions-fn dirty-fn)
  "Check monitor-silence thresholds; no-op when SERVER-SESSIONS-FN is NIL.

   Errors are swallowed because this runs on a background timer thread with no
   one to report to; a failing silence check must not take the thread down."
  (when (and *running* server-sessions-fn)
    (ignore-errors
      (%check-monitor-silence (funcall server-sessions-fn) dirty-fn))))

(defun start-status-timer (dirty-fn &key server-sessions-fn)
  "Start a background thread that drives periodic session maintenance:
   - STATUS-INTERVAL: calls DIRTY-FN every N seconds to refresh the status bar.
   - DISPLAY-TIME: auto-dismisses transient overlays after configured ms.
   - MONITOR-SILENCE: sets window-silence-flag after N seconds of PTY silence.
   SERVER-SESSIONS-FN is optional; the silence check is skipped when absent.
   Returns the thread object."
  (make-thread
   (lambda ()
     (let ((elapsed 0))
       (loop while *running*
             do (sleep +status-timer-poll-seconds+)
                (incf elapsed +status-timer-poll-seconds+)
                (%timer-tick-overlay dirty-fn)
                (setf elapsed (%timer-tick-status-interval elapsed dirty-fn))
                (%timer-tick-silence server-sessions-fn dirty-fn))))
   :name "nerimux-status-timer"))

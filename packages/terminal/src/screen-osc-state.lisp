(in-package #:nerimux/terminal/actions)

;;;; Small screen-state setters driven by escape sequences: focus-event reports
;;;; (?1004), the pending-BEL flag, the OSC 0/2/7 title & cwd, the XTPUSHTITLE/
;;;; XTPOPTITLE title stack, and the OSC 110/111 default-colour resets.
;;; ── Focus event reporting (?1004) ──────────────────────────────────────────
;;;
;;; When an application enables focus events, it expects the terminal to deliver
;;; ESC[I when focus is gained and ESC[O when focus is lost.  This pure function
;;; produces those report bytes; the dispatch layer writes them to the pane's PTY
;;; as the active pane changes.  Returns NIL when the screen has not opted in, so
;;; callers can treat "no report" and "focus events off" uniformly.
;;;
;;; defparameter rather than defconstant is used for the report strings because
;;; string identity (EQL) cannot be guaranteed across image reloads — SBCL would
;;; signal a redefinition error for defconstant with a new string object.
(defparameter +focus-gained-report+
  (format nil "~C[I" #\Escape)
  "VT sequence delivered to a focused application when it gains terminal focus.")

(defparameter +focus-lost-report+
  (format nil "~C[O" #\Escape)
  "VT sequence delivered to a focused application when it loses terminal focus.")

(defun focus-event-report (screen focused-p)
  "Focus-tracking report bytes for SCREEN: ESC[I when FOCUSED-P, ESC[O otherwise.
   Returns NIL unless the screen enabled focus events (?1004h)."
  (when (screen-focus-events screen)
    (if focused-p
        +focus-gained-report+
        +focus-lost-report+)))

;;; ── BEL pending ──────────────────────────────────────────────────────────────
(defun set-bell-pending (screen)
  "Mark SCREEN as having a pending BEL (bell event) to be processed by the renderer."
  (setf (screen-bell-pending screen) t))

;;; ── Screen title ─────────────────────────────────────────────────────────────
(defun set-screen-title (screen title)
  "Set the OSC window title of SCREEN to TITLE string."
  (setf (screen-title screen) title))

(defun set-screen-cwd (screen cwd)
  "Set the OSC 7 current working directory of SCREEN to CWD string."
  (setf (screen-cwd screen) cwd))

(defun push-title-stack (screen)
  "XTPUSHTITLE (CSI > Ps t): push the current title onto the title stack.
   The stack is bounded to +title-stack-max-depth+ entries (xterm limit);
   when the limit is exceeded the oldest entry is silently discarded."
  (let ((stack (screen-title-stack screen)))
    (setf (screen-title-stack screen) (cons (screen-title screen)
                                            (if (>= (length stack)
                                                    +title-stack-max-depth+)
                                                (butlast stack)
                                                stack)))))

(defun pop-title-stack (screen)
  "XTPOPTITLE (CSI < Ps t): pop and restore the most recently pushed title.
   A pop on an empty stack is a silent no-op, matching xterm behaviour."
  (let ((stack (screen-title-stack screen)))
    (when stack
      (setf (screen-title screen) (car stack)
            (screen-title-stack screen) (cdr stack)))))

(defun reset-osc-default-fg (screen)
  "OSC 110: reset the default foreground colour to +osc-default-fg+ (white).
   Called when the application sends OSC 110 ST to restore the default fg."
  (setf (screen-osc-default-fg screen) +osc-default-fg+))

(defun reset-osc-default-bg (screen)
  "OSC 111: reset the default background colour to +osc-default-bg+ (black).
   Called when the application sends OSC 111 ST to restore the default bg."
  (setf (screen-osc-default-bg screen) +osc-default-bg+))

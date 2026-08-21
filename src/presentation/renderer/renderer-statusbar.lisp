(in-package #:nerimux/renderer)

;;;; Status bar composition for the nerimux renderer.
;;;;
;;;; This file owns the status bar: format composition and the
;;;; render-status-bar entry point.  It has no knowledge of session-frame
;;;; compositing; that lives in renderer-compose.lisp.
;;;;
;;;; R2.2/R2.3 fixed every status-bar option at its registered default (none
;;;; of them could ever have been overridden without a config file, which
;;;; R2.1 removed) and replaced format-template expansion with direct string
;;;; composition — see the R2 renderer report for the full mapping.  In
;;;; particular: window-status-current-style is always "reverse" (SGR "7"),
;;;; window-status-style (inactive) is always "" (no SGR), the
;;;; window-status-activity-style/bell-style alert priority table is gone
;;;; with the rest of the alert machinery (R1.10), and window-status-format
;;;; / window-status-current-format are always " #{window_index}:#{window_name} "
;;;; / " #{window_index}:#{window_name}* " — composed directly below instead
;;;; of expanded from that template string.
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format → renderer-style
;;;;             → renderer-statusbar-layout → renderer-pane
;;;;             → renderer-statusbar → renderer-compose

;;; The status line is one row at the bottom, always (requirements §1.4).
;;; nerimux/options:status-line-count and +max-status-lines+ (the "status"
;;; option could pick 0..5 rows) are gone with domain/options (R2.2) — this
;;; is the one place that concept survives, as a fixed constant instead of a
;;; cross-package function call, so anything outside nerimux/renderer that
;;; still needs to reserve rows for the status line (e.g. pane-area layout)
;;; has exactly one definition to reference rather than each side keeping
;;; its own copy of "1".

(defconstant +status-line-rows+ 1
  "Rows reserved at the bottom of the terminal for the status line.")

;;; ── Status bar data formatters (pure) ─────────────────────────────────────

(defun %current-time-string ()
  "Return HH:MM string from the system clock.
   status-right's fixed value is \"#{time}\"; this is the direct-composition
   replacement for the domain/format expansion of that template (R2.3).
   domain/format is deleted (R2.3), so this is reimplemented locally rather
   than called across a package that no longer exists."
  (multiple-value-bind (sec min hour) (get-decoded-time)
    (declare (ignore sec))
    (format nil "~2,'0D:~2,'0D" hour min)))

(defun %status-pane-indicator (active-pane)
  "Pane-number string for the status bar, or empty string when ACTIVE-PANE is NIL."
  (if active-pane (format nil " #~D" (pane-id active-pane)) ""))

(defconstant +sgr-window-tab-active+ "7"
  "SGR for the active window's status-bar tab: window-status-current-style's
   fixed value \"reverse\" (SGR 7, reverse video).")

(defun %render-window-tab (window active-window window-stream)
  "Write WINDOW's status-bar tab label to WINDOW-STREAM: \" I:NAME \" for a
   non-active window, \" I:NAME* \" (reverse video) for the active one — the
   fixed content of window-status-format / window-status-current-format,
   composed directly instead of expanded from those templates (R2.3).
   window-status-style (inactive) is always \"\" (no SGR, R2.2): only the
   active window's tab carries a style."
  (let* ((active-p (eq window active-window))
         (label    (if active-p
                       (format nil " ~D:~A* " (window-id window) (window-name window))
                       (format nil " ~D:~A "  (window-id window) (window-name window)))))
    (if active-p
        (progn
          (%emit-sgr window-stream +sgr-window-tab-active+)
          (write-string label window-stream)
          (reset-attrs window-stream))
        (write-string label window-stream))))

(defconstant +window-status-separator+ " "
  "Text between window tabs in the status bar: window-status-separator's
   fixed value (a single space, its registered default).")

(defun %status-window-list-styled (session active-window)
  "Window-tab string with current-style applied to the active window entry."
  (with-output-to-string (window-stream)
    (let ((first-p t))
      (dolist (window (nerimux/model:session-windows-in-index-order session))
        (unless first-p (write-string +window-status-separator+ window-stream))
        (setf first-p nil)
        (%render-window-tab window active-window window-stream)))))

(defun %status-left-text (session active-window active-pane)
  "Left portion of the status bar: session/window/pane info.
   Uses %status-window-list-styled so the active window's tab is styled."
  (format nil " ~A~A~A"
          (session-name session)
          (%status-window-list-styled session active-window)
          (%status-pane-indicator active-pane)))

(defun %render-status-line (stream status-row sgr-code line)
  "Emit a fully-composed status LINE at STATUS-ROW, wrapped in SGR-CODE, then reset."
  (move-to stream status-row 0)
  (%emit-sgr stream sgr-code)
  (write-string line stream)
  (reset-attrs stream))

(defun %status-bar-default-segments (session sgr-code)
  "Return (values LEFT RIGHT): the left segment is the session/window/pane
   summary, the right segment the clock — status-left / status-right's
   fixed values, composed directly (R2.3) rather than expanded from their
   registered templates \"[#{session_name}]\" / \"#{time}\", which — with no
   config able to override either option away from its own default — were
   never actually rendered even before R2: the original
   %status-format-or-default only expanded a registered template when the
   live option value had diverged from that same default, which with no
   config could never happen, so it always fell back to exactly the
   procedural composition kept here."
  (let* ((active-window (session-active-window session))
         (active-pane   (session-active-pane session))
         (left-raw      (%status-expand-style-blocks
                         (%status-left-text session active-window active-pane)
                         sgr-code))
         (right-raw     (%status-expand-style-blocks
                         (%current-time-string)
                         sgr-code))
         (style-sgr   (%status-segment-style-sgr sgr-code))
         (left        (%apply-segment-style
                       (%clamp-status-segment left-raw 40)
                       style-sgr sgr-code))
         (right       (%apply-segment-style
                       (%clamp-status-segment right-raw 40)
                       style-sgr sgr-code)))
    (values left right)))

(defun render-status-bar (stream session terminal-rows terminal-cols
                          &key (status-row (- terminal-rows +status-line-rows+)))
  "Draw the status bar at STATUS-ROW.  STATUS-ROW defaults to the bottom
   row (TERMINAL-ROWS minus +status-line-rows+) — status-position's fixed
   value is \"bottom\" (§1.4), which is always this same row, so the caller
   never needs to pass a top-row override any more (R2.2).  SGR-CODE is
   +sgr-default-status+: status-style's fixed value is \"\" (R2.2), which
   parse-style-string/style-to-sgr always resolved to that same constant
   before R2.4 deleted the parser.  Justification (status-justify) is
   always \"left\" (its registered default; R2.2)."
  (let ((sgr-code +sgr-default-status+))
    (multiple-value-bind (left right)
        (%status-bar-default-segments session sgr-code)
      (%render-status-line stream status-row sgr-code
                           (%status-justify-line left right terminal-cols "left")))))

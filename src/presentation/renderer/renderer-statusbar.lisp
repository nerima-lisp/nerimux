(in-package #:nerimux/renderer)

;;;; Status bar composition for the nerimux renderer.
;;;;
;;;; This file owns the status bar: option lookup, format expansion, justify
;;;; logic, and the render-status-bar entry point.  It has no knowledge of
;;;; session-frame compositing; that lives in renderer-compose.lisp.
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format → renderer-style
;;;;             → renderer-statusbar-layout → renderer-pane → renderer-overlay
;;;;             → renderer-statusbar → renderer-compose

;;; ── Alert-priority style table ─────────────────────────────────────────────
;;;
;;; define-window-alert-priority-table expands to a COND expression that walks
;;; a declarative priority list: each entry is (condition-expr style-var) where
;;; style-var must already be bound to a string.  The first entry whose
;;; condition is true AND whose style is non-empty wins.  FALLBACK is the
;;; unconditional last resort.
;;;
;;; Matches the define-csi-rules / define-alert-action-rules convention used
;;; elsewhere: declarative (fact . result) pairs instead of hand-rolled cond.

(defmacro define-window-alert-priority-table (fallback &rest entries)
  "Expand to a COND expression that returns the first non-empty style whose
   alert condition is true, or FALLBACK when no alert matches.
   Each ENTRY is (condition-expr style-var).
   Condition-expr and style-var are evaluated once, in order."
  `(cond
     ,@(mapcar (lambda (entry)
                 (destructuring-bind (condition style-var) entry
                   `((and ,condition (plusp (length ,style-var))) ,style-var)))
               entries)
     (t ,fallback)))

;;; ── Status bar data formatters (pure) ─────────────────────────────────────

(defun %status-pane-indicator (active-pane)
  "Pane-number string for the status bar, or empty string when ACTIVE-PANE is NIL."
  (if active-pane (format nil " #~D" (pane-id active-pane)) ""))

(defun %window-has-bell-p (window)
  "T when WINDOW's sticky bell flag is set and monitor-bell is on for it.
   Mirrors the #{window_bell_flag} computation in format-context.lisp."
  (and (nerimux/options:get-option-for-context "monitor-bell" :window window)
       (window-bell-flag window)))

(defun %window-option (window name)
  "Read NAME from WINDOW's option context."
  (nerimux/options:get-option-for-context name :window window))

(defun %window-status-style (session window active-p)
  "Resolve the status-bar style string for WINDOW's tab.
   Active window → window-status-current-style.  For a non-active window, the
   highest-priority non-empty alert style wins: bell > activity > last
   (previously active) > the normal window-status-style.  Every option is read
   per-window via get-option-for-context, so alert styles can be set per-window."
  (if active-p
      (%window-option window "window-status-current-style")
      (let ((bell-style     (%window-option window "window-status-bell-style"))
            (activity-style (%window-option window "window-status-activity-style"))
            (last-style     (%window-option window "window-status-last-style"))
            (normal-style   (%window-option window "window-status-style")))
        (define-window-alert-priority-table normal-style
          ((%window-has-bell-p window)              bell-style)
          ((window-activity-flag window)            activity-style)
          ((eq window (session-last-window session)) last-style)))))

(defun %render-window-tab (session window active-window window-stream)
  "Write WINDOW's status-bar tab label (format-expanded, per-window styled,
   with any inline #[attr] blocks resolved) to WINDOW-STREAM.  ACTIVE-WINDOW
   selects window-status-current-format/-style over the plain variants."
  (let* ((context  (nerimux/format:format-context-from-window session window))
         (active-p (eq window active-window))
         (fmt      (nerimux/options:get-option-for-context
                    (if active-p "window-status-current-format" "window-status-format")
                    :window window))
         ;; Style honors alert state (bell/activity/last) for non-active windows.
         (style    (%window-status-style session window active-p))
         (label    (nerimux/format:expand-format fmt context)))
    ;; Apply the per-window style, then expand any inline #[attr] blocks
    ;; embedded in the label.  Within a window label, #[default] reverts to
    ;; the window's own style (or the status default when it is unstyled).
    ;; STYLED-P is true when we emitted a wrapper SGR or the label injected
    ;; one, so the trailing reset keeps colour from bleeding into the
    ;; separator / next window.
    (let* ((sgr-code (when (and style (plusp (length style)))
                       (%status-sgr-from-style style)))
           (expanded (%status-expand-style-blocks
                      label (or sgr-code +sgr-default-status+)))
           (styled-p (or sgr-code (not (eq expanded label)))))
      (when sgr-code
        (%emit-sgr window-stream sgr-code))
      (write-string expanded window-stream)
      (when styled-p
        (reset-attrs window-stream)))))

(defun %status-window-list-styled (session active-window)
  "Window-tab string with current-style applied to the active window entry.
   Uses window-status-format, window-status-current-format, window-status-separator,
   window-status-current-style, window-status-style, and the alert-state styles
   (window-status-{bell,activity,last}-style).
   The format/style options are resolved PER WINDOW via get-option-for-context
   (pane→window→global→default), so e.g. `set-window-option -t :2
   window-status-current-style fg=red` styles only that window's tab.  A
   non-active window with a pending bell, unseen activity, or that is the last
   (previously active) window picks up the corresponding alert style
   (bell > activity > last > normal).
   window-status-separator stays global — it sits between windows and has no
   single owning window."
  (let ((separator (nerimux/options:get-option "window-status-separator" " ")))
    (with-output-to-string (window-stream)
      (let ((first-p t))
        (dolist (window (nerimux/model:session-windows-in-index-order session))
          (unless first-p (write-string separator window-stream))
          (setf first-p nil)
          (%render-window-tab session window active-window window-stream))))))

(defun %status-left-text (session active-window active-pane)
  "Left portion of the status bar: prompt text or session/window/pane info.
   Uses %status-window-list-styled so per-window style options take effect."
  (if (prompt-active-p)
      (prompt-text)
      (format nil " ~A~A~A"
              (session-name session)
              (%status-window-list-styled session active-window)
              (%status-pane-indicator active-pane))))

(defun %render-status-line (stream status-row sgr-code line)
  "Emit a fully-composed status LINE at STATUS-ROW, wrapped in SGR-CODE, then reset."
  (move-to stream status-row 0)
  (%emit-sgr stream sgr-code)
  (write-string line stream)
  (reset-attrs stream))

(defun %render-status-bar-format0 (stream status-row sgr-code status-fmt0 context terminal-cols)
  "Render the single-template status bar path for STATUS-FMT0."
  (%render-status-line stream status-row sgr-code
                       (%compose-aligned-line
                        (nerimux/format:expand-format-safe status-fmt0 context)
                        sgr-code terminal-cols)))

(defun %status-bar-default-segments (session context sgr-code)
  "Return the fallback status-bar segments and justification mode.
   The left segment includes either prompt text or the session/window/pane
   summary; the right segment uses status-right or the default clock string."
  (let* ((active-window (session-active-window session))
         (active-pane   (session-active-pane session))
         (left-raw      (%status-expand-style-blocks
                         (if (prompt-active-p)
                             (prompt-text)
                             (%status-format-or-default
                              "status-left" context
                              (lambda () (%status-left-text session active-window active-pane))))
                         sgr-code))
         (right-raw   (%status-expand-style-blocks
                       (%status-format-or-default
                        "status-right" context #'nerimux/format::%current-time-string)
                       sgr-code))
         (left-style-sgr  (%status-segment-style-sgr "status-left-style"  sgr-code))
         (right-style-sgr (%status-segment-style-sgr "status-right-style" sgr-code))
         (left        (%apply-segment-style
                       (%clamp-status-segment
                        left-raw (nerimux/options:get-option "status-left-length" 40))
                       left-style-sgr sgr-code))
         (right       (%apply-segment-style
                       (%clamp-status-segment
                        right-raw (nerimux/options:get-option "status-right-length" 40))
                       right-style-sgr sgr-code))
         (justify     (nerimux/options:get-option "status-justify" "left")))
    (values left right justify)))

(defun %render-status-bar-default (stream session status-row sgr-code context terminal-cols)
  "Render the default left/right status bar path."
  ;; Expand inline #[attr] style blocks into SGR escapes; #[default] reverts to
  ;; SGR-CODE (the base status style) so the bar's bg/fg returns between segments.
  (multiple-value-bind (left right justify)
      (%status-bar-default-segments session context sgr-code)
    (%render-status-line stream status-row sgr-code
                         (%status-justify-line left right terminal-cols justify))))

(defun render-status-bar (stream session terminal-rows terminal-cols
                          &key (status-row (1- terminal-rows)))
  "Draw the status bar at STATUS-ROW with dynamic format string expansion.
   STATUS-ROW defaults to (1- TERMINAL-ROWS), i.e. the bottom row.
   Respects status-style, status-justify, status-left-length, status-right-length,
   and window-status-current-style options."
  (let* ((active-window (session-active-window session))
         (active-pane   (session-active-pane session))
         ;; Pass terminal dimensions so #{client_width} / #{client_height} work
         ;; in status-left, status-right, and window-status-format strings.
         (context       (nerimux/format:format-context-from-session
                         session active-window active-pane
                       :client-width  terminal-cols
                       :client-height (max 0 (- terminal-rows 1))))
         (sgr-code    (%status-sgr-from-style (%effective-status-style)))
         (status-fmt0 (nerimux/options:get-option "status-format[0]" "")))
    ;; status-format[0] template path: when SET (and no prompt is active) the bar
    ;; is rendered from that single format, with #[align=…] regions positioned by
    ;; %compose-aligned-line and #{W:…}/#{…} expanded.  Procedural path follows.
    (if (and (stringp status-fmt0) (plusp (length status-fmt0)) (not (prompt-active-p)))
        (%render-status-bar-format0 stream status-row sgr-code status-fmt0 context terminal-cols)
        (%render-status-bar-default stream session status-row sgr-code context terminal-cols))))

(defun render-extra-status-line (stream session terminal-cols row index)
  "Render the INDEX-th extra status line (INDEX >= 1) at ROW from the option
   status-format[INDEX], expanded against SESSION's format context and padded to
   TERMINAL-COLS with the base status style.  An unset/blank status-format[INDEX]
   draws a blank styled row (which is still required, since the pane area has
   shrunk to leave this row to the status region)."
  (let* ((fmt      (nerimux/options:get-option
                    (format nil "status-format[~D]" index) ""))
         (sgr-code (%status-sgr-from-style
                    (%effective-status-style)))
         (context  (nerimux/format:format-context-from-session
                    session (session-active-window session)
                    (session-active-pane session)
                    :client-width terminal-cols))
         ;; Expand #{...} (leaving #[...] markers intact) then compose via the
         ;; same align-aware path as status-format[0], so #[align=right]/#[align=
         ;; centre] work in the extra rows too.  An empty format composes to a
         ;; blank styled row.
         (expanded (if (and (stringp fmt) (plusp (length fmt)))
                       (nerimux/format:expand-format-safe fmt context)
                       ""))
         (line     (%compose-aligned-line expanded sgr-code terminal-cols)))
    (%render-status-line stream row sgr-code line)))

       ;; status-line-count and its parser moved to nerimux/options (domain).
;;; The row count is derived from the `status' option in exactly one place now;
;;; this file used to hold a second copy that the pane layout did not consult.
;;; See src/domain/options/options-api.lisp.

(defun render-status-region (stream session terminal-rows terminal-cols lines position)
  "Render a LINES-row status region.  The main bar (status-left, the window
   list, and status-right) is drawn on the outer edge — the bottom-most row when
   POSITION is \"bottom\" (the default), the top-most row when \"top\" — matching
   the single-line layout.  Additional rows render status-format[1..LINES-1]
   stacked inward from the main bar."
  (let* ((bottom-p (string/= position "top"))
         (main-row (if bottom-p (1- terminal-rows) 0)))
    (render-status-bar stream session terminal-rows terminal-cols
                       :status-row main-row)
    (loop for index from 1 below lines
          for row = (if bottom-p (- main-row index) (+ main-row index))
          do (render-extra-status-line stream session terminal-cols row index))))


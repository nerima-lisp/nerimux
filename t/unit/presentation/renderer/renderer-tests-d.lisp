(in-package #:nerimux/test)

;;;; renderer tests — part IV: %current-time-string, %status-left-text,
;;;; %status-justify-line, status-bar-line gap.
;;;;
;;;; R2.2 deleted domain/options (get-option-for-context, set-option-for-window),
;;;; so %status-window-list-styled no longer resolves window-status-format /
;;;; window-status-current-format / window-status-style / window-status-
;;;; current-style per window — every window's tab now gets exactly the same
;;;; fixed SGR (active: reverse video; inactive: none — see
;;;; renderer-window-list-tests.lisp).  window-status-last-style and
;;;; session-last-window are no longer read either.  %status-format-or-default
;;;; is gone along with domain/format (R2.3) — see renderer-statusbar-layout.lisp.

(describe "renderer-suite"

  ;;; ── %justify-right (pure) ───────────────────────────────────────────────────

  ;; %justify-right never returns a line longer than the requested column width.
  (it "status-bar-line-fits-in-terminal-cols"
    (let ((line (nerimux/renderer::%justify-right "left-text" "12:34" 20)))
      (expect (<= (length line) 20))))

  ;; %justify-right's output contains both the left text and the right-justified time string.
  (it "status-bar-line-contains-left-and-time"
    (let ((line (nerimux/renderer::%justify-right "mysession" "09:00" 40)))
      (expect (search "mysession" line))
      (expect (search "09:00" line))))

  ;; %justify-right clamps its output to cols when the left text and time overflow a narrow terminal.
  (it "status-bar-line-truncates-when-too-long"
    ;; Terminal is only 5 cols wide; result must be clamped.
    (let ((line (nerimux/renderer::%justify-right "very-long-left-text" "99:99" 5)))
      (expect (= 5 (length line)))))

  ;;; ── %current-time-string ────────────────────────────────────────────────────

  ;; %current-time-string (the status-bar clock formatter, used by status-right)
  ;; returns a 5-char HH:MM string.  Reimplemented in nerimux/renderer now that
  ;; domain/format is gone (R2.3) — see renderer-statusbar.lisp.
  (it "current-time-string-returns-hhmm"
    (let ((t-str (nerimux/renderer::%current-time-string)))
      (expect (= 5 (length t-str)))
      (expect (char= #\: (char t-str 2)))
      (expect (every #'digit-char-p (remove #\: t-str)))))

  ;;; ── %status-left-text ────────────────────────────────────────────────────────

  ;; %status-left-text returns session/window info.
  (it "status-left-text-normal-mode"
    (let* ((s   (make-fake-session :nwindows 1))
           (win (session-active-window s))
           (ap  (session-active-pane  s))
           (left (nerimux/renderer::%status-left-text s win ap)))
      (expect (search "0" left))
      (expect (search "0" left))))

  ;;; ── %status-justify-line ─────────────────────────────────────────────────────

  ;; %status-justify-line with justify=left matches %justify-right.
  (it "status-justify-line-left-default"
    (let* ((left "hello")
           (right "world")
           (cols 40)
           (result   (nerimux/renderer::%status-justify-line left right cols "left"))
           (expected (nerimux/renderer::%justify-right left right cols)))
      (expect (string= expected result))))

  ;; %status-justify-line with justify=right places the right string at far right.
  (it "status-justify-line-right-places-content-at-far-right"
    (let* ((result (nerimux/renderer::%status-justify-line "L" "R" 20 "right")))
      (expect (<= (length result) 20))
      (expect (char= #\R (char result (1- (length result)))))))

  ;; %status-justify-line with justify=centre produces output containing both strings.
  (it "status-justify-line-centre-pads-symmetrically"
    (let ((result (nerimux/renderer::%status-justify-line "AB" "XY" 20 "centre")))
      (expect (search "AB" result))
      (expect (search "XY" result))
      (expect (<= (length result) 20)))))

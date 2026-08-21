(in-package #:nerimux)

;;;; PTY reader alert helpers.
;;;;
;;;; This file contains the remain-on-exit banner helpers used by
;;;; runtime-reader.lisp.

;;; ANSI SGR sequence displayed on the pane when remain-on-exit is active.
;;; SGR 7 = reverse video; SGR 0 (implicit via reset) restores normal.
;;; Defined as a variable (not defconstant) because SBCL's DEFCONSTANT
;;; requires EQL identity across reloads, which string values fail.
(defvar +remain-on-exit-message+
  (format nil "~C[7m[Process exited]~C[m" #\Escape #\Escape)
  "Fallback reverse-video banner written to the pane screen when remain-on-exit is
   set but remain-on-exit-format is empty or fails to expand.")

(defun %num-or-empty (value)
  "Render VALUE as a decimal string when present, otherwise the empty string."
  (if value (format nil "~D" value) ""))

(defun %pane-death-context (pane)
  "A minimal format context carrying PANE's death record, so
   remain-on-exit-format can reference #{pane_dead_status} /
   #{pane_dead_signal} / #{pane_dead_time} (a full session context is
   intentionally not built on the reader thread)."
  (list :pane-dead        "1"
        :pane-dead-status (%num-or-empty (nerimux/model:pane-dead-status pane))
        :pane-dead-signal (%num-or-empty (nerimux/model:pane-dead-signal pane))
        :pane-dead-time   (%num-or-empty (nerimux/model:pane-dead-time pane))))

(defun %expand-remain-on-exit-format (pane)
  "Expand remain-on-exit-format for PANE, or NIL when the option is empty or
   expansion fails."
  (let ((fmt (ignore-errors
               (nerimux/options:get-option-for-context "remain-on-exit-format"
                                                       :pane pane))))
    (when (and fmt (plusp (length fmt)))
      (ignore-errors (nerimux/format:expand-format
                      fmt (%pane-death-context pane))))))

(defun %remain-on-exit-banner-text (pane)
  "Return the formatted remain-on-exit text for PANE, or NIL when unavailable."
  (%expand-remain-on-exit-format pane))

(defun %remain-on-exit-banner (pane)
  "The reverse-video banner for a pane kept open by remain-on-exit: the
   remain-on-exit-format option expanded as a format string and wrapped in reverse
   video.  Falls back to +remain-on-exit-message+ on any error or an empty result.
   Expanded against the pane's death-record context so the tmux default's
   #{pane_dead_status}/#{pane_dead_signal}/#{pane_dead_time} references resolve."
  (let ((text (%remain-on-exit-banner-text pane)))
    (if (and text (plusp (length text)))
        (format nil "~C[7m~A~C[m" #\Escape text #\Escape)
        +remain-on-exit-message+)))

(defun %write-remain-on-exit-banner (pane)
  "Write the remain-on-exit banner bytes to PANE's screen.
   This is a side-effectful helper extracted from reader-eof-state so the CPS
   state function itself remains pure (only returns the next state)."
  (let ((screen (pane-screen pane)))
    (when screen
      (let ((banner-bytes (cl-codec-kit:string-to-octets (%remain-on-exit-banner pane)
                                                  :encoding :utf-8)))
        (nerimux/terminal/emulator:screen-process-bytes screen banner-bytes)))))

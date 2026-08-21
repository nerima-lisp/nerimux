(in-package #:nerimux/test)

;;;; status-bar segment style, on/off, and BEL — part II
;;;;
;;;; §1.4/R2.2/R2.3 fixed the status bar's shape: `status` is always "on"
;;;; (exactly one row, always drawn — R6.5), `status-position` is always
;;;; "bottom" (window-tree.lisp:%assign-window-tree no longer offsets panes
;;;; for a top-positioned bar), multi-line status (`status` 2..5,
;;;; `status-format[N]`) and status-left/-right's #{...} template expansion
;;;; are gone outright — render-extra-status-line, status-line-count, and
;;;; %status-sgr-from-style no longer exist.  See renderer-statusbar.lisp and
;;;; renderer-statusbar-layout.lisp.

(describe "renderer-suite"

  ;;; ── %status-segment-style-sgr ────────────────────────────────────────────────

  ;; %status-segment-style-sgr always returns its BASE-SGR argument unchanged —
  ;; status-left-style/status-right-style (domain/options, deleted R2.2) both
  ;; defaulted to "", which always fell back to the base style, so the
  ;; per-segment override branch is gone rather than hardcoded to a dead value.
  (it "status-segment-style-sgr-returns-base-unchanged"
    (expect (string= "44;97" (nerimux/renderer::%status-segment-style-sgr "44;97"))))

  ;; %apply-segment-style wraps TEXT in the segment SGR and reverts to the base.
  (it "apply-segment-style-wraps-and-reverts"
    (let ((out (nerimux/renderer::%apply-segment-style "TEXT" "31" "44")))
      (expect (search (format nil "~C[31m" #\Escape) out))
      (expect (search "TEXT" out))
      (expect (search (format nil "~C[44m" #\Escape) out))))

  ;; %apply-segment-style returns TEXT unchanged when the segment SGR equals the base.
  (it "apply-segment-style-noop-when-equal-to-base"
    (expect (string= "TEXT" (nerimux/renderer::%apply-segment-style "TEXT" "44" "44"))))

  ;;; ── status is always on ──────────────────────────────────────────────────────

  ;; render-session-to-string always emits the blue status-bar background —
  ;; the `status` option (domain/options, deleted R2.2) always resolved to
  ;; "on" with no config able to turn it off.
  (it "render-session-always-shows-status-bar"
    (let* ((sess (make-renderer-test-session 20 5))
           (out  (render-session-to-string sess 6 20)))
      (expect (search (format nil "~C[44;97m" #\Escape) out))))

  ;;; ── BEL rendering ────────────────────────────────────────────────────────────

  ;; render-session-to-string emits BEL (byte 7) when bell-pending is T and clears
  ;; the flag; emits no BEL when bell-pending is NIL.
  (it "render-bel-table"
    (dolist (row '((t   "bell-pending T: BEL emitted and flag cleared")
                   (nil "bell-pending NIL: BEL absent")))
      (destructuring-bind (initial-pending desc) row
        (declare (ignore desc))
        (let* ((sess  (make-renderer-test-session 20 5))
               (ap    (session-active-pane sess))
               (sc    (pane-screen ap)))
          (setf (nerimux/terminal/types:screen-bell-pending sc) initial-pending)
          (let ((out (render-session-to-string sess 6 20)))
            (expect (if initial-pending
                        (find (code-char 7) out)
                        (null (find (code-char 7) out))))
            (when initial-pending
              (expect (nerimux/terminal/types:screen-bell-pending sc) :to-be-falsy))))))))

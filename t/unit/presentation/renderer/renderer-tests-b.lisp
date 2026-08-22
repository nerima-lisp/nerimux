(in-package #:nerimux/test)

;;;; status-bar on/off, and BEL — part II
;;;;
;;;; §1.4/R2.2/R2.3 fixed the status bar's shape: `status` is always "on"
;;;; (exactly one row, always drawn — R6.5), `status-position` is always
;;;; "bottom" (window-tree.lisp:%assign-window-tree no longer offsets panes
;;;; for a top-positioned bar), multi-line status (`status` 2..5,
;;;; `status-format[N]`) and status-left/-right's #{...} template expansion
;;;; are gone outright — render-extra-status-line, status-line-count,
;;;; %status-sgr-from-style, %status-segment-style-sgr, and
;;;; %apply-segment-style (the per-segment style override, R6.5's fixed
;;;; single-SGR status line has no per-segment style left to apply) no
;;;; longer exist.  See renderer-statusbar.lisp and
;;;; renderer-statusbar-layout.lisp.

(describe "renderer-suite"

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
          (format *error-output* "~&DIAG initial-pending=~S active-pane-eq-ap=~S bell-pending-before-render=~S active-pane-fd=~S window-panes-count=~S~%"
                  initial-pending
                  (eq ap (nerimux::session-active-pane sess))
                  (nerimux/terminal/types:screen-bell-pending sc)
                  (nerimux/model:pane-fd (nerimux::session-active-pane sess))
                  (length (nerimux/model:window-panes (nerimux::session-active-window sess))))
          (let ((out (render-session-to-string sess 6 20)))
            (format *error-output* "~&DIAG bell-pending-after-render=~S out-has-bel=~S out-length=~S~%"
                    (nerimux/terminal/types:screen-bell-pending sc)
                    (and (find (code-char 7) out) t)
                    (length out))
            (expect (if initial-pending
                        (find (code-char 7) out)
                        (null (find (code-char 7) out))))
            (when initial-pending
              (expect (nerimux/terminal/types:screen-bell-pending sc) :to-be-falsy))))))))

(in-package #:nerimux/test)

;;;; status-left-text copy mode, zoom suppression — part III

(describe "renderer-suite"

  ;; The five protocol-toggle tests that used to open this block
  ;; (mouse-reporting, extended-keys x3, focus-reporting) went with the
  ;; functions they covered: each emitted a sequence for a caller that no longer
  ;; exists, and these tests were the only thing keeping them alive.  See
  ;; src/presentation/renderer/renderer-compose-protocols.lisp.

  ;;; ── %status-left-text with copy mode ─────────────────────────────────────────

  ;; %status-left-text with copy mode active no longer includes the old copy indicator.
  (it "status-left-text-copy-mode-has-no-indicator"
    (let* ((sess   (make-fake-session :nwindows 1))
           (ap     (session-active-pane  sess))
           (screen (pane-screen ap)))
      ;; Enable copy mode with a non-zero offset.
      (setf (screen-copy-mode-p   screen) t
            (screen-copy-offset   screen) 2)
      (let ((left (nerimux/renderer::%status-left-text ap)))
        (expect (null (search "COPY" left)))
        (expect (null (search "+2" left))))))

  ;;; ── %render-panes-and-borders zoom suppression (coverage gap) ───────────────

  ;; %render-panes-and-borders emits no border characters when window-zoom-p is T.
  (it "render-panes-borders-suppressed-when-zoomed"
    ;; tl-window calls window-relayout which runs screen-resize on each pane,
    ;; so pane screens match the assigned geometry (fix for INVALID-ARRAY-INDEX-ERROR
    ;; that occurred when manual make-window with 1×1 screens met an 81×24 layout).
    (let* ((l0  (tl-leaf 1 1 1))
           (l1  (tl-leaf 2 1 1))
           (win (tl-window (make-layout-split :h l0 l1) 24 81))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (session-select-window sess win)
      (setf (nerimux/window:window-zoom-p win) t)
      (let ((buf (make-string-output-stream)))
        (nerimux/renderer::%render-panes-and-borders
         buf sess win (nerimux/window:window-panes win) (nerimux/window:window-active win) 81)
        (let ((out (get-output-stream-string buf)))
          (expect (null (find #\│ out))))))))

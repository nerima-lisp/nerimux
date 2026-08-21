(in-package #:nerimux/test)

;;;; focus/keys sequences, justify, cursor-shape, inline-style — part III

(describe "renderer-suite"

  ;; The five protocol-toggle tests that used to open this block
  ;; (mouse-reporting, extended-keys x3, focus-reporting) went with the
  ;; functions they covered: each emitted a sequence for a caller that no longer
  ;; exists, and these tests were the only thing keeping them alive.  See
  ;; src/presentation/renderer/renderer-compose-protocols.lisp.

  ;;; ── %status-pane-indicator with non-nil pane ─────────────────────────────────

  ;; %status-pane-indicator with pane id 99 returns a string containing '#99'.
  (it "status-pane-indicator-formats-pane-id"
    (let* ((screen (make-screen 10 5))
           (pane   (make-pane :id 99 :x 0 :y 0 :width 10 :height 5 :fd -1 :screen screen)))
      (let ((out (nerimux/renderer::%status-pane-indicator pane)))
        (expect (search "#99" out)))))

  ;;; ── %status-left-text with copy mode ─────────────────────────────────────────

  ;; %status-left-text with copy mode active no longer includes the old copy indicator.
  (it "status-left-text-copy-mode-has-no-indicator"
    (let* ((sess   (make-fake-session :nwindows 1))
           (win    (session-active-window sess))
           (ap     (session-active-pane  sess))
           (screen (pane-screen ap)))
      ;; Enable copy mode with a non-zero offset.
      (setf (screen-copy-mode-p   screen) t
            (screen-copy-offset   screen) 2)
      (let ((left (nerimux/renderer::%status-left-text sess win ap)))
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
      (setf (nerimux/model:window-zoom-p win) t)
      (let ((buf (make-string-output-stream)))
        (nerimux/renderer::%render-panes-and-borders
         buf sess win (nerimux/model:window-panes win) (nerimux/model:window-active win) 81)
        (let ((out (get-output-stream-string buf)))
          (expect (null (find #\│ out)))))))

  ;;; ── %justify-right and %justify-centre (coverage gap) ───────────────────────

  ;; %justify-right puts the right text at the far right of the line.
  (it "justify-right-places-right-text-flush-right"
    (let* ((left  "left-text")
           (right "right")
           (cols  30)
           (line  (nerimux/renderer::%justify-right left right cols)))
      (expect (<= (length line) cols))
      (expect (char= #\t (char line (1- (length line)))))
      (expect (search left line))))

  ;; %justify-right truncates when cols is very small.
  (it "justify-right-short-cols-truncates"
    (let ((line (nerimux/renderer::%justify-right "LLLL" "RRRR" 5)))
      (expect (<= (length line) 5))))

  ;; %justify-centre produces output containing both left and right strings.
  (it "justify-centre-contains-both-strings"
    (let ((line (nerimux/renderer::%justify-centre "LEFT" "RIGHT" 30)))
      (expect (search "LEFT"  line))
      (expect (search "RIGHT" line))
      (expect (<= (length line) 30))))

  ;; %justify-centre truncates when cols is smaller than the combined content.
  (it "justify-centre-short-cols-truncates"
    (let ((line (nerimux/renderer::%justify-centre "AAAA" "BBBB" 5)))
      (expect (<= (length line) 5)))))

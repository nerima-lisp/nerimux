(in-package #:nerimux/test)

;;;; status window-list formatting.
;;;;
;;;; window-status-format / window-status-current-format / window-status-style
;;;; / window-status-current-style (domain/options, deleted R2.2) are fixed:
;;;; the active window's tab is always wrapped in SGR 7 (reverse video —
;;;; window-status-current-style's registered default), a non-active tab
;;;; never carries SGR at all (window-status-style's registered default is
;;;; "") — see renderer-statusbar.lisp:%render-window-tab.  Per-window
;;;; overrides (set-option-for-window) and inline #[…] blocks inside the
;;;; window-status format templates no longer exist: those templates are now
;;;; composed directly instead of expanded (R2.3), so there is no live
;;;; template text left for a #[…] block to appear in.

(describe "renderer-suite/window-list"

  ;; The active window's tab carries the * marker.
  (it "status-window-list-brackets-active-window"
    (let* ((sess (make-renderer-test-session 20 5 :content ""))
           (win  (session-active-window sess))
           (out  (nerimux/renderer::%status-window-list-styled sess win)))
      (expect (search "1:1" out))
      (expect (search "*" out))))

  ;; Both active and inactive windows appear, with the * marker on the active
  ;; window's tab only.
  (it "status-window-list-two-windows-formats-both"
    (let* ((s0   (make-screen 10 5))
           (p0   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5 :fd -1 :screen s0))
           (w0   (make-window :id 1 :name "alpha" :width 10 :height 5 :panes (list p0)))
           (s1   (make-screen 10 5))
           (p1   (make-pane :id 2 :x 0 :y 0 :width 10 :height 5 :fd -1 :screen s1))
           (w1   (make-window :id 2 :name "beta"  :width 10 :height 5 :panes (list p1)))
           (sess (make-session :id 1 :name "0" :windows (list w0 w1))))
      (window-select-pane w0 p0)
      (window-select-pane w1 p1)
      (session-select-window sess w1)
      (let ((out (nerimux/renderer::%status-window-list-styled sess w1)))
        (expect (search "beta*" out))
        (expect (search "alpha" out))
        (expect (null (search "alpha*" out))))))

  ;; The active window's tab is wrapped in SGR 7 (reverse video) and reset
  ;; afterwards — window-status-current-style's fixed value.
  (it "status-window-list-active-window-wrapped-in-reverse-sgr"
    (let* ((sess (make-renderer-test-session 20 5 :content ""))
           (win  (session-active-window sess))
           (out  (nerimux/renderer::%status-window-list-styled sess win)))
      (expect (search (format nil "~C[7m" #\Escape) out))
      (expect (search (format nil "~C[0m" #\Escape) out))))

  ;; A non-active window's tab carries no SGR at all — window-status-style's
  ;; fixed value is the empty string.
  (it "status-window-list-inactive-window-has-no-sgr"
    (let* ((s0   (make-screen 10 5))
           (p0   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5 :fd -1 :screen s0))
           (w0   (make-window :id 1 :name "alpha" :width 10 :height 5 :panes (list p0)))
           (s1   (make-screen 10 5))
           (p1   (make-pane :id 2 :x 0 :y 0 :width 10 :height 5 :fd -1 :screen s1))
           (w1   (make-window :id 2 :name "beta"  :width 10 :height 5 :panes (list p1)))
           (sess (make-session :id 1 :name "0" :windows (list w0 w1))))
      (window-select-pane w0 p0)
      (window-select-pane w1 p1)
      (session-select-window sess w1)
      (let* ((out           (nerimux/renderer::%status-window-list-styled sess w1))
             (sgr-pos        (search (format nil "~C[7m" #\Escape) out))
             (before-active  (subseq out 0 sgr-pos)))
        ;; The text before the active window's SGR-7 wrap is window 1's
        ;; (alpha, inactive) label — it must carry no escape sequence.
        (expect (null (search (string #\Escape) before-active)))))))

(in-package #:nerimux/test/model)

;;;; window tests — part B: last-window by recency, move-window, swap-window,
;;;; find-window-by-name, list-windows-format, auto-rename-from-osc,
;;;; window-remove-pane, window-last-active-time, window-layout-cycle-index.
(describe "model-suite"

  ;;; ── last-window by recency ───────────────────────────────────────────────────

  ;; session-last-window returns the window with the second-highest last-active-time.
  (it "last-window-by-recency"
    (let* ((w0 (make-window :id 1 :name "0" :last-active-time 100))
           (w1 (make-window :id 2 :name "1" :last-active-time 200))
           (w2 (make-window :id 3 :name "2" :last-active-time 300))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      (session-select-window sess w2)
      ;; second-most-recent is w1 (time 200)
      (expect (eq w1 (session-last-window sess)))))

  ;; session-last-window returns NIL when there is only one window.
  (it "last-window-single-window-returns-nil"
    (let* ((w0   (make-window :id 1 :name "0" :last-active-time 100))
           (sess (make-session :id 1 :name "s" :windows (list w0))))
      (expect (null (session-last-window sess)))))

  ;;; ── move-window-reorders ─────────────────────────────────────────────────────

  ;; session-move-window moves a window to the requested position.
  (it "move-window-reorders"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w2 (make-window :id 3 :name "2"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      ;; Move w0 (currently index 0) to index 2 (the end).
      (session-move-window sess w0 2)
      (expect (equal (list w1 w2 w0) (session-windows sess)))))

  ;; session-move-window clamps out-of-range target to last valid index.
  (it "move-window-clamps-to-last"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-move-window sess w0 99)
      (expect (equal (list w1 w0) (session-windows sess)))))

  ;; session-move-window clamps a negative target index to 0 (the first position).
  (it "move-window-clamps-negative-index-to-zero"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w2 (make-window :id 3 :name "2"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      ;; Move w2 (currently index 2) to a negative target — clamps to 0.
      (session-move-window sess w2 -5)
      (expect (equal (list w2 w0 w1) (session-windows sess)))))

  ;;; ── swap-window-exchanges ────────────────────────────────────────────────────

  ;; session-swap-windows exchanges two windows at the given indices.
  (it "swap-window-exchanges"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w2 (make-window :id 3 :name "2"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      (session-swap-windows sess 0 2)
      (expect (equal (list w2 w1 w0) (session-windows sess)))))

  ;; session-swap-windows with equal indices leaves the list unchanged.
  (it "swap-window-same-index-is-noop"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-swap-windows sess 0 0)
      (expect (equal (list w0 w1) (session-windows sess)))))

  ;; session-swap-windows with an out-of-range index leaves the list unchanged.
  (it "swap-window-out-of-range-is-noop"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-swap-windows sess 0 5)
      (expect (equal (list w0 w1) (session-windows sess)))))

  ;; session-move-window is a no-op when the window is not in the session.
  (it "move-window-returns-unchanged-when-window-not-found"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w-other (make-window :id 99 :name "other"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-move-window sess w-other 0)
      (expect (equal (list w0 w1) (session-windows sess))))))

;;; ── find-window-by-name ──────────────────────────────────────────────────────

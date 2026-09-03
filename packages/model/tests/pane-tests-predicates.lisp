(in-package #:nerimux/test/model)

;;;; Pane tests - predicates and hit-testing.
(describe "model-suite"

  ;;; ── pane-at-position hit test ────────────────────────────────────────────────

  ;; pane-at-position returns the pane containing (x,y), or NIL for the separator gap.
  (it "pane-at-position-table"
    (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
           (p1  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :width 81 :height 24
                             :panes (list p0 p1)
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0)
                                      (make-layout-leaf p1)
                                      1/2))))
      (expect (eq  p0  (pane-at-position win 10 5)))
      (expect (eq  p1  (pane-at-position win 50 5)))
      (expect (null    (pane-at-position win 40 5)))))

  ;; pane-at-position returns NIL when the window has no panes.
  (it "pane-at-position-returns-nil-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :panes nil)))
      (expect (null (pane-at-position win 0 0)))))

  ;;; ── pane-live-p direct unit tests ────────────────────────────────────────────

  ;; pane-live-p returns T only when fd > 0; fd <= 0 and NIL are all not-live.
  ;; :nil sentinel means pass NIL directly instead of creating a pane.
  ;; Each row: (fd expected description).
  (it "pane-live-p-table"
    (dolist (row '((5    t   "pane with fd > 0 must be live")
                   (-1   nil "pane with fd = -1 must not be live")
                   (0    nil "pane with fd = 0 must not be reported as live")
                   (:nil nil "pane-live-p NIL must return NIL")))
      (destructuring-bind (fd expected desc) row
        (declare (ignore desc))
        (let ((pane (if (eq fd :nil)
                        nil
                        (make-pane :id 1 :x 0 :y 0 :width 80 :height 24
                                   :fd fd :pid -1 :screen (make-screen 80 24)))))
          (if expected
              (expect (pane-live-p pane) :to-be-truthy)
              (expect (pane-live-p pane) :to-be-falsy)))))))

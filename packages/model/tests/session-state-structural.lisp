(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "attach-full-screen-pane-structural"
    (let* ((p0   (make-no-pty-pane 1 0 0 80 23))
           (win  (make-window :id 0 :name "bash" :width 80 :height 23
                              :panes (list p0)
                              :active p0
                              :tree (make-layout-leaf p0)))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (session-select-window sess win)
      (expect (eq p0 (window-active-pane win)))
      (expect (= 1 (length (window-panes win))))
      (expect (window-tree win) :to-be-truthy)
      (expect (eq p0 (session-active-pane sess)))))


  (it "session-active-window-falls-back-to-first"
    (let* ((w0   (make-window :id 0 :name "a"))
           (w1   (make-window :id 1 :name "b"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (expect (eq w0 (session-active-window sess)))))


  (it "session-active-pane-nil-for-windowless-session"
    (let ((sess (make-session :id 1 :name "s" :windows nil)))
      (expect (null (session-active-pane sess)))))


  (it "session-last-active-defaults-zero"
    (let ((sess (make-session :id 1 :name "s")))
      (expect (= 0 (session-last-active sess)))))


  (it "all-panes-multi-pane-window"
    (let* ((p0   (make-no-pty-pane 1 0 0 40 24))
           (p1   (make-no-pty-pane 2 41 0 40 24))
           (win  (make-window :id 0 :name "w" :panes (list p0 p1)))
           (sess (make-session :id 1 :name "s" :windows (list win))))
      (let ((panes (all-panes sess)))
        (expect (= 2 (length panes)))
        (expect (member p0 panes) :to-be-truthy)
        (expect (member p1 panes) :to-be-truthy))))


  (it "session-select-window-updates-window-last-active-time"
    (let* ((w0   (make-window :id 0 :name "a" :last-active-time 0))
           (sess (make-session :id 1 :name "s" :windows (list w0))))
      (let ((before (get-universal-time)))
        (session-select-window sess w0)
        (expect (>= (window-last-active-time w0) before)))))


  (it "next-window-id-respects-base-index"
    (let* ((sess (make-session :id 1 :name "s" :windows nil)))
      (expect (>= (nerimux/session::%next-window-id sess 5) 5))))


  (it "session-struct-default-values-table"
    (let ((sess (make-session :id 1 :name "test")))
      (expect (= 1 (session-id sess)))
      (expect (string= "test" (session-name sess)))
      (dolist (row (list (list (session-windows sess)       "session-windows must default to NIL")
                         (list (session-active-window sess) "active window must be NIL (no windows)")
                         (list (session-clients sess)       "session-clients must default to NIL")))
        (destructuring-bind (val desc) row
          (declare (ignore desc))
          (expect (null val)))))))

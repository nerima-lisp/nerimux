(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "last-window-by-recency"
    (let* ((w0 (make-window :id 1 :name "0" :last-active-time 100))
           (w1 (make-window :id 2 :name "1" :last-active-time 200))
           (w2 (make-window :id 3 :name "2" :last-active-time 300))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      (session-select-window sess w2)
      (expect (eq w1 (session-last-window sess)))))

  (it "last-window-single-window-returns-nil"
    (let* ((w0   (make-window :id 1 :name "0" :last-active-time 100))
           (sess (make-session :id 1 :name "s" :windows (list w0))))
      (expect (null (session-last-window sess)))))


  (it "move-window-reorders"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w2 (make-window :id 3 :name "2"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      (session-move-window sess w0 2)
      (expect (equal (list w1 w2 w0) (session-windows sess)))))

  (it "move-window-clamps-to-last"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-move-window sess w0 99)
      (expect (equal (list w1 w0) (session-windows sess)))))

  (it "move-window-clamps-negative-index-to-zero"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w2 (make-window :id 3 :name "2"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      (session-move-window sess w2 -5)
      (expect (equal (list w2 w0 w1) (session-windows sess)))))


  (it "swap-window-exchanges"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w2 (make-window :id 3 :name "2"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1 w2))))
      (session-swap-windows sess 0 2)
      (expect (equal (list w2 w1 w0) (session-windows sess)))))

  (it "swap-window-same-index-is-noop"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-swap-windows sess 0 0)
      (expect (equal (list w0 w1) (session-windows sess)))))

  (it "swap-window-out-of-range-is-noop"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-swap-windows sess 0 5)
      (expect (equal (list w0 w1) (session-windows sess)))))

  (it "move-window-returns-unchanged-when-window-not-found"
    (let* ((w0 (make-window :id 1 :name "0"))
           (w1 (make-window :id 2 :name "1"))
           (w-other (make-window :id 99 :name "other"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (session-move-window sess w-other 0)
      (expect (equal (list w0 w1) (session-windows sess))))))

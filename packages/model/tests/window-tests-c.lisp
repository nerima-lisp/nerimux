(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "window-remove-pane-empties-single-pane-window"
    (let* ((p0  (make-no-pty-pane 1 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p0)
                             :tree (make-layout-leaf p0))))
      (window-select-pane win p0)
      (let ((result (window-remove-pane win p0)))
        (expect (null result))
        (expect (null (window-panes win)))
        (expect (null (window-tree win))))))

  (it "window-remove-pane-returns-sibling"
    (with-h-split-window (win p0 p1)
      (let ((survivor (window-remove-pane win p0)))
        (expect (not (null survivor)))
        (expect (= 1 (length (window-panes win)))))))


  (it "window-last-active-time-updated-on-select"
    (let* ((p0  (make-no-pty-pane 1 0 0 20 5))
           (win (make-window :id 1 :name "w" :width 20 :height 5
                             :panes (list p0) :last-active-time 0)))
      (let ((before (get-universal-time)))
        (window-select-pane win p0)
        (expect (>= (window-last-active-time win) before)))))


  (it "window-layout-cycle-index-defaults-zero"
    (let ((win (make-window :id 1 :name "w")))
      (expect (= 0 (window-layout-cycle-index win)))))


  (it "ensure-window-fits-does-not-mutate-on-matching-size"
    (let* ((p0  (make-no-pty-pane 1 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :tree (make-layout-leaf p0)
                             :panes (list p0) :active p0)))
      (let ((x0-before (pane-x p0))
            (y0-before (pane-y p0)))
        (nerimux/window::ensure-window-fits win 24 80)
        (expect (= x0-before (pane-x p0)))
        (expect (= y0-before (pane-y p0))))))


  (it "window-slot-defaults-table"
    (dolist (c '((nerimux/window:window-zoom-p      nil "window-zoom-p defaults nil")
                 (nerimux/window:window-zoom-tree    nil "window-zoom-tree defaults nil")
                 (window-last-active                nil "window-last-active defaults nil")
                 (window-automatic-rename-p          t  "window-automatic-rename-p defaults t")))
      (destructuring-bind (accessor expected desc) c
        (declare (ignore desc))
        (let ((win (make-window :id 1 :name "w")))
          (expect (equal expected (funcall accessor win)))))))

  (it "window-automatic-rename-p-settable"
    (let ((win (make-window :id 1 :name "w" :automatic-rename-p nil)))
      (expect (null (window-automatic-rename-p win)))))


  (it "window-active-pane-falls-back-to-first-pane"
    (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
           (p1  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :panes (list p0 p1))))
      (expect (eq p0 (window-active-pane win)))))


  (it "window-select-pane-records-previous-as-last-active"
    (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
           (p1  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :panes (list p0 p1))))
      (window-select-pane win p0)
      (expect (null (window-last-active win)))
      (window-select-pane win p1)
      (expect (eq p0 (window-last-active win)))))


  (it "window-remove-pane-absent-pane-returns-first-pane"
    (let* ((p0  (make-no-pty-pane 1 0 0 40 24))
           (p1  (make-no-pty-pane 2 41 0 40 24))
           (win (make-window :id 1 :name "w" :width 81 :height 24
                             :panes (list p0 p1)
                             :tree (make-layout-leaf p0))))
      (let ((result (window-remove-pane win p1)))
        (expect result :to-be-truthy)
        (expect (window-tree win) :to-be-truthy))))


  (it "new-split-ratio-additional-cases"
    (dolist (entry
             '((:h 100 3/4 10 t   85/100 "grow :h from 3/4 ratio")
               (:v 40  1/4  5 t   15/40  "grow :v from 1/4 ratio")
               (:h 60  2/3  1 nil 39/60  "shrink :h from 2/3 ratio")))
      (destructuring-bind (orient avail cur-ratio delta grow-first expected desc) entry
        (declare (ignore desc))
        (let ((result (nerimux/window::%new-split-ratio orient avail cur-ratio delta grow-first)))
          (expect (equal expected result))))))


  (it "window-id-slot-accessible"
    (let ((win (make-window :id 42 :name "test")))
      (expect (= 42 (window-id win)))))

  (it "window-name-slot-accessible"
    (let ((win (make-window :id 1 :name "mywin")))
      (expect (string= "mywin" (window-name win)))))


  (it "window-width-height-slot-accessible"
    (let ((win (make-window :id 1 :name "w" :width 120 :height 40)))
      (expect (= 120 (window-width  win)))
      (expect (= 40  (window-height win)))))


  (it "window-remove-pane-clears-pane-window-sole-pane"
    (let* ((p0  (make-no-pty-pane 1 0 0 80 24))
           (win (make-window :id 1 :name "w" :width 80 :height 24
                             :panes (list p0)
                             :tree (make-layout-leaf p0))))
      (setf (pane-window p0) win)
      (window-remove-pane win p0)
      (expect (null (pane-window p0)))))

  (it "window-remove-pane-clears-pane-window-preserves-survivor"
    (with-h-split-window (win p0 p1)
      (setf (pane-window p0) win
            (pane-window p1) win)
      (window-remove-pane win p0)
      (expect (null (pane-window p0)))
      (expect (eq win (pane-window p1)))))

  )

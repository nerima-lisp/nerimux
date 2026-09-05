(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "pane-feed-processes-bytes-into-screen"
    (let* ((screen (make-screen 10 5))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                              :fd -1 :pid -1 :screen screen)))
      (pane-feed pane (cl-codec-kit:string-to-octets "hi" :encoding :utf-8))
      (expect (char= #\h (cell-char (screen-cell screen 0 0))))
      (expect (char= #\i (cell-char (screen-cell screen 1 0))))
      (expect (= 2 (screen-cursor-x screen)))))


  (it "pane-reposition-updates-geometry-and-screen"
    (let ((pane (make-no-pty-pane 1 0 0 20 5)))
      (pane-reposition pane 3 7 40 10)
      (check-table (list (list (pane-x pane) 3 "pane-x must be 3 after reposition")
                         (list (pane-y pane) 7 "pane-y must be 7 after reposition")
                         (list (pane-width pane) 40 "pane-width must be 40 after reposition")
                         (list (pane-height pane) 10 "pane-height must be 10 after reposition")
                         (list (screen-width (pane-screen pane)) 40 "screen-width must match new pane width")
                         (list (screen-height (pane-screen pane)) 10 "screen-height must match new pane height")))))

  (it "pane-reposition-zero-origin"
    (let ((pane (make-no-pty-pane 1 5 3 10 5)))
      (pane-reposition pane 0 0 80 24)
      (check-table (list (list (pane-x pane) 0 "pane-x must be 0 after reposition to origin")
                         (list (pane-y pane) 0 "pane-y must be 0 after reposition to origin")
                         (list (pane-width pane) 80 "pane-width must be 80")
                         (list (pane-height pane) 24 "pane-height must be 24")
                         (list (screen-width (pane-screen pane)) 80 "screen width must match pane width")
                         (list (screen-height (pane-screen pane)) 24 "screen height must match pane height")))))

  (it "pane-reposition-returns-no-value"
    (let ((pane (make-no-pty-pane 1 0 0 5 5)))
      (expect (progn (pane-reposition pane 0 0 10 10) t) :to-be-truthy)))



  (it "pane-reposition-degenerate-dimensions-skip-the-pty-resize"
    (let* ((calls nil)
           (nerimux/ports:*resize-pty*
             (lambda (fd rows cols) (push (list fd rows cols) calls)))
           (pane (make-no-pty-pane 1 0 0 20 5)))
      (setf (pane-fd pane) 3)              ; positive: the fd guard passes
      (finishes (pane-reposition pane 0 0 40 0)
                "a zero height must not reach set-pty-size")
      (expect (null calls))
      (finishes (pane-reposition pane 0 0 0 10)
                "a zero width must not reach set-pty-size")
      (expect (null calls))
      (pane-reposition pane 0 0 40 10)
      (expect (equal (list (list 3 10 40)) calls))))


  (it "next-pane-id-returns-one-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :panes nil)))
      (expect (= 1 (nerimux/window::next-pane-id win)))))

  (it "next-pane-id-fills-lowest-gap"
    (let* ((p2  (make-no-pty-pane 2 0 0 10 5))
           (p3  (make-no-pty-pane 3 0 0 10 5))
           (win (make-window :id 1 :name "w" :panes (list p2 p3))))
      (expect (= 1 (nerimux/window::next-pane-id win)))))

  )

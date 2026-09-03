(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "close-pane-pty-passes-fd-then-pid"
    (let ((pane (make-pane :id 91 :x 0 :y 0 :width 20 :height 5
                           :fd 41 :pid 42 :screen (make-screen 20 5)))
          (received :never-called))
      (let ((nerimux/ports:*close-pty*
              (lambda (master-fd child-pid)
                (setf received (list master-fd child-pid)))))
        (close-pane-pty pane))
      (expect (equal (list 41 42) received))))

  (it "retire-pane-pty-clears-identifiers-before-closing"
    (let ((pane (make-pane :id 92 :x 0 :y 0 :width 20 :height 5
                           :fd 51 :pid 52 :screen (make-screen 20 5)))
          (observed :never-called))
      (let ((nerimux/ports:*close-pty*
              (lambda (master-fd child-pid)
                (setf observed (list master-fd child-pid
                                     (pane-fd pane) (pane-pid pane))))))
        (nerimux/commands:retire-pane-pty pane))
      (expect (equal (list 51 52 -1 -1) observed))
      (expect (= -1 (pane-fd pane)))
      (expect (= -1 (pane-pid pane))))))

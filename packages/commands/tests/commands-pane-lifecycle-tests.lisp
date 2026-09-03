(in-package #:nerimux/test/commands)

;;;; pane lifecycle command tests: close-pane-pty
(describe "commands-suite"

  ;;; -- close-pane-pty ----------------------------------------------------------
  ;;;
  ;;; These lifecycle operations are reached from the reader thread on pane EOF
  ;;; (runtime-reader.lisp:96) and from server shutdown (server.lisp:160).

  ;; Both parameters are integers, so transposing them compiles clean and
  ;; type-checks -- and would send SIGHUP to whatever process happens to hold the
  ;; fd's number.  Nothing else in the suite pins the order.
  ;;
  ;; The stub replaces the PORT (nerimux/ports:*close-pty*), not
  ;; nerimux/pty:pty-close's function cell.  close-pane-pty routes through the
  ;; port, and install-pty-port captured #'pty-close as a function OBJECT at
  ;; startup -- so rebinding that symbol's fdefinition afterwards would not
  ;; intercept anything, and this test would pass while measuring nothing.
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

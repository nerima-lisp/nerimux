(in-package #:nerimux/test)

;;;; pane lifecycle command tests: close-pane-pty

(describe "commands-suite"

  ;;; -- close-pane-pty ----------------------------------------------------------
  ;;;
  ;;; The one symbol in commands-core.lisp still reached from a live path: the
  ;;; reader thread calls it on pane EOF (runtime-reader.lisp:96) and server
  ;;; shutdown calls it for every pane (server.lisp:160).  It had no coverage.

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
      (expect (equal (list 41 42) received)))))

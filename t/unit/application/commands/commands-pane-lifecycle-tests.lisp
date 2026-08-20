(in-package #:nerimux/test)

;;;; pane lifecycle command tests: close-pane-pty

(describe "commands-suite"

  ;;; -- close-pane-pty ----------------------------------------------------------
  ;;;
  ;;; The one symbol in commands-core.lisp still reached from a live path: the
  ;;; reader thread calls it on pane EOF (runtime-reader.lisp:96) and server
  ;;; shutdown calls it for every pane (server.lisp:160).  It had no coverage.

  ;; Both of pty-close's parameters are integers, so transposing them compiles
  ;; clean and type-checks -- and would send SIGHUP to whatever process happens
  ;; to hold the fd's number.  Nothing else in the suite pins the order.
  (it "close-pane-pty-passes-fd-then-pid"
    (let ((pane (make-pane :id 91 :x 0 :y 0 :width 20 :height 5
                           :fd 41 :pid 42 :screen (make-screen 20 5)))
          (received :never-called)
          (saved (fdefinition 'nerimux/pty:pty-close)))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/pty:pty-close)
                   (lambda (master-fd child-pid)
                     (setf received (list master-fd child-pid))))
             (close-pane-pty pane)
             (expect (equal (list 41 42) received)))
        (setf (fdefinition 'nerimux/pty:pty-close) saved))))

  ;; Why the wrapper exists at all: server shutdown walks every pane in turn, so
  ;; one already-closed fd must not abort the teardown of the panes after it.
  ;; pty-close has its own ignore-errors, but this asserts the guarantee at the
  ;; boundary its callers actually depend on.
  (it "close-pane-pty-swallows-a-signalling-pty-close"
    (let ((pane (make-pane :id 92 :x 0 :y 0 :width 20 :height 5
                           :fd 7 :pid 8 :screen (make-screen 20 5)))
          (saved (fdefinition 'nerimux/pty:pty-close)))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/pty:pty-close)
                   (lambda (master-fd child-pid)
                     (declare (ignore master-fd child-pid))
                     (error "simulated teardown failure")))
             (expect (null (close-pane-pty pane))))
        (setf (fdefinition 'nerimux/pty:pty-close) saved)))))

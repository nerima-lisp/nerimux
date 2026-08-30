(in-package #:nerimux/test)

;;;; clear-history under server state.
;;;;
;;;; Moved out of packages/commands/tests/commands-tests-h.lisp when
;;;; application/commands became nerimux-commands. WITH-COMMAND-TEST-STATE binds
;;;; nerimux::*server-sessions*, a BOOTSTRAP internal that a unit test system
;;;; cannot see when run on its own, so this case belongs above every unit.

(defun %clear-history-fixture ()
  "Single-pane window \"w\" in session \"0\" whose screen has a non-empty
   scrollback.  Returns (values sess win screen)."
  (let* ((screen (make-screen 10 3))
         (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 3
                            :fd -1 :pid -1 :screen screen))
         (win    (make-window :id 1 :name "w" :width 10 :height 3
                              :tree (make-layout-leaf pane) :panes (list pane)))
         (sess   (make-session :id 1 :name "0" :windows (list win))))
    (session-select-window sess win)
    (window-select-pane win pane)
    (setf (nerimux/terminal/types:screen-scrollback screen)
          (list (make-array 10 :initial-element
                            (nerimux/terminal/types:make-cell
                             :char #\X :fg 7 :bg 0 :attrs 0 :width 1))))
    (values sess win screen)))

(describe "commands-clear-history-suite"

  ;; clear-scrollback empties the target pane's scrollback.
  (it "cmd-clear-history-clears-scrollback"
    (multiple-value-bind (sess win screen) (%clear-history-fixture)
      (declare (ignore win))
      (with-command-test-state (sess)
        (nerimux/terminal/actions:clear-scrollback screen)
        (expect (null (nerimux/terminal/types:screen-scrollback screen)))))))

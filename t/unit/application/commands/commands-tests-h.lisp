(in-package #:nerimux/test)

;;;; copy-mode-exit, clear-history — part VI

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

(describe "commands-suite"

  ;;; ── copy-mode-exit ───────────────────────────────────────────────────────────

  ;; copy-mode-exit resets copy-mode-p, offset, mark, cursor, and selecting.
  (it "copy-mode-exit-resets-all-copy-state"
    (let ((s (copy-mode-screen)))
      ;; Set all copy-mode fields to non-default values.
      (setf (nerimux/terminal/types:screen-copy-offset    s) 5
            (nerimux/terminal/types:screen-copy-mark      s) (cons 2 3)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 2 5)
            (nerimux/terminal/types:screen-copy-selecting s) t)
      (nerimux/commands::copy-mode-exit s)
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (expect (= 0 (nerimux/terminal/types:screen-copy-offset s)))
      (expect (null (nerimux/terminal/types:screen-copy-mark s)))
      (expect (null (nerimux/terminal/types:screen-copy-cursor s)))
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)))

  ;;; ── clear-history ────────────────────────────────────────────────────────────

  ;; clear-scrollback empties the target pane's scrollback.
  (it "cmd-clear-history-clears-scrollback"
    (multiple-value-bind (sess win screen) (%clear-history-fixture)
      (declare (ignore win))
      (with-command-test-state (sess)
        (nerimux/terminal/actions:clear-scrollback screen)
        (expect (null (nerimux/terminal/types:screen-scrollback screen)))))))

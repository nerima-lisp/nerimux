(in-package #:nerimux/test)

;;;; last-window command behavior
;;;;
;;;; find-window and next-window/previous-window were entirely dispatch-layer:
;;;; the tmux command-line argument parsing (%cmd-find-window-arg,
;;;; %cmd-next-window-arg, %cmd-previous-window-arg) and the underlying search
;;;; predicate (%window-matches-pattern-p) and cyclic-advance logic all lived in
;;;; the deleted src/application/dispatch tree, with no surviving replacement.
;;;; last-window's underlying action -- select the window with the
;;;; second-highest last-active-time -- survives as SESSION-LAST-WINDOW, a pure
;;;; query the format layer already relies on; combined with the surviving
;;;; SESSION-SELECT-WINDOW it reproduces the old command's effect directly.

(defun %find-window-fixture ()
  "Session \"0\" with three named windows alpha/beta/gamma (alpha current).
   Returns (values sess wa wb wg)."
  (let* ((pa (%make-test-pane :id 1))
         (pb (%make-test-pane :id 2))
         (pg (%make-test-pane :id 3))
         (wa (make-window :id 1 :name "alpha" :width 20 :height 5
                          :tree (make-layout-leaf pa) :panes (list pa)))
         (wb (make-window :id 2 :name "beta" :width 20 :height 5
                          :tree (make-layout-leaf pb) :panes (list pb)))
         (wg (make-window :id 3 :name "gamma" :width 20 :height 5
                          :tree (make-layout-leaf pg) :panes (list pg)))
         (sess (make-session :id 1 :name "0" :windows (list wa wb wg))))
    (session-select-window sess wa)
    (values sess wa wb wg)))

(describe "commands-suite"

  ;;; ── last-window ──────────────────────────────────────────────────────────────

  ;; last-window selects the window with the second-highest last-active-time --
  ;; the previously active window.
  (it "cmd-last-window-selects-previously-active-window"
    (multiple-value-bind (sess wa wb wg) (%find-window-fixture)
      (declare (ignore wg))
      (session-select-window sess wb)
      (setf (nerimux/model:window-last-active-time wb) 40
            (nerimux/model:window-last-active-time wa) 30)
      (session-select-window sess (nerimux/model:session-last-window sess))
      (expect (eq wa (session-active-window sess)))))

  ;; last-window targeting a different session selects THAT session's previous
  ;; window, leaving the current session's active window unchanged.
  (it "cmd-last-window-t-targets-named-session"
    (let* ((pc (%make-test-pane :id 1)) (poa (%make-test-pane :id 2))
           (pob (%make-test-pane :id 3))
           (cur-win (make-window :id 1 :name "cur" :width 20 :height 5
                                 :tree (make-layout-leaf pc) :panes (list pc)))
           (cur     (make-session :id 1 :name "cur" :windows (list cur-win)))
           (o-a (make-window :id 2 :name "oa" :width 20 :height 5
                             :tree (make-layout-leaf poa) :panes (list poa)))
           (o-b (make-window :id 3 :name "ob" :width 20 :height 5
                             :tree (make-layout-leaf pob) :panes (list pob)))
           (other (make-session :id 2 :name "other" :windows (list o-a o-b))))
      (session-select-window cur cur-win)
      (session-select-window other o-b)
      (setf (nerimux/model:window-last-active-time o-b) 40
            (nerimux/model:window-last-active-time o-a) 30)
      (session-select-window other (nerimux/model:session-last-window other))
      (expect (eq o-a (session-active-window other)))
      (expect (eq cur-win (session-active-window cur))))))

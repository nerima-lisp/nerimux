(in-package #:nerimux/test)

;;;; Layout fixture that needs the event loop.
;;;;
;;;; The rest of helpers-layout-fixtures.lisp moved to packages/model/tests/
;;;; when domain/model became nerimux-model. This one stayed: it wraps its body
;;;; in WITH-LOOP-STATE, which binds nerimux::*running*, so a DOMAIN unit cannot
;;;; carry it.

(defmacro with-two-pane-v-session ((sess-var win-var p0-var p1-var) &body body)
  "Bind SESS-VAR WIN-VAR P0-VAR P1-VAR to a 2-pane vertical split session:
   p0 (y=0 h=10) above p1 (y=11 h=10), window 80x21, first pane active.
   Runs BODY inside WITH-LOOP-STATE for event-loop isolation."
  `(let* ((,p0-var  (make-no-pty-pane 1 0  0 80 10))
          (,p1-var  (make-no-pty-pane 2 0 11 80 10))
          (,win-var (make-window :id 1 :name "w" :width 80 :height 21
                                 :panes (list ,p0-var ,p1-var)
                                 :tree (make-layout-split :v
                                          (make-layout-leaf ,p0-var)
                                          (make-layout-leaf ,p1-var)
                                          1/2)))
          (,sess-var (make-session :id 1 :name "0" :windows (list ,win-var))))
     (window-select-pane ,win-var ,p0-var)
     (session-select-window ,sess-var ,win-var)
     (with-loop-state ,@body)))

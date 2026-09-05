(in-package #:nerimux/test)

(defmacro with-dead-pane ((pane-var) &body body)
  "Bind PANE-VAR to a standard dead pane (fd=-1, pid=-1, 5×3 screen) for BODY.
   Eliminates the repeated (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 5 3))
   boilerplate."
  `(let ((,pane-var (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 5 3))))
     ,@body))

(describe "runtime-suite"


  (it "runtime-globals-exist"
    (expect (boundp 'nerimux::*running*))
    (expect (boundp 'nerimux::*dirty*))
    (expect (boundp 'nerimux::*resize-pending*))
    (expect (integerp nerimux::*term-rows*))
    (expect (integerp nerimux::*term-cols*)))

  (it "runtime-term-dimensions-positive-table"
    (dolist (row (list (list nerimux::*term-rows* "*term-rows*")
                       (list nerimux::*term-cols* "*term-cols*")))
      (destructuring-bind (val name) row
        (declare (ignore name))
        (expect (plusp val)))))

  (it "runtime-reader-thread-join-timeout-is-constant"
    (expect (integerp nerimux::+reader-thread-join-timeout+))
    (expect (plusp nerimux::+reader-thread-join-timeout+)))


  (it "pane-reader-loop-is-fbound"
    (expect (fboundp 'nerimux::%pane-reader-loop)))

  (it "pane-reader-loop-exits-when-running-nil"
    (with-dead-pane (pane)
      (let ((nerimux::*running* nil)
            (nerimux::*dirty*   nil))
        (finishes (nerimux::%pane-reader-loop pane))
        (expect nerimux::*dirty* :to-be-falsy))))


  (it "reader-eof-state-always-returns-nil"
    (with-dead-pane (pane)
      (expect (null (nerimux::reader-eof-state pane))))))

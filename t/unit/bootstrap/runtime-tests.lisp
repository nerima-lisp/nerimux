(in-package #:nerimux/test)

;;;; global variables, pane-reader-loop, reader EOF, and alert actions

;;; ── Test fixture macros ──────────────────────────────────────────────────────

(defmacro with-dead-pane ((pane-var) &body body)
  "Bind PANE-VAR to a standard dead pane (fd=-1, pid=-1, 5×3 screen) for BODY.
   Eliminates the repeated (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 5 3))
   boilerplate."
  `(let ((,pane-var (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 5 3))))
     ,@body))

(describe "runtime-suite"

  ;;; ── Global variables exist and have sensible types ───────────────────────────

  ;; *running*, *dirty*, *resize-pending*, *term-rows*, *term-cols* are all boundp.
  (it "runtime-globals-exist"
    (expect (boundp 'nerimux::*running*))
    (expect (boundp 'nerimux::*dirty*))
    (expect (boundp 'nerimux::*resize-pending*))
    (expect (integerp nerimux::*term-rows*))
    (expect (integerp nerimux::*term-cols*)))

  ;; *term-rows* and *term-cols* both default to positive integers.
  (it "runtime-term-dimensions-positive-table"
    (dolist (row (list (list nerimux::*term-rows* "*term-rows*")
                       (list nerimux::*term-cols* "*term-cols*")))
      (destructuring-bind (val name) row
        (declare (ignore name))
        (expect (plusp val)))))

  ;; +reader-thread-join-timeout+ is a positive integer constant.
  (it "runtime-reader-thread-join-timeout-is-constant"
    (expect (integerp nerimux::+reader-thread-join-timeout+))
    (expect (plusp nerimux::+reader-thread-join-timeout+)))

  ;;; ── %pane-reader-loop ────────────────────────────────────────────────────────

  ;; %pane-reader-loop is a defined function (data/logic separation from start-reader-thread).
  (it "pane-reader-loop-is-fbound"
    (expect (fboundp 'nerimux::%pane-reader-loop)))

  ;; %pane-reader-loop exits immediately when *running* is NIL without error.
  (it "pane-reader-loop-exits-when-running-nil"
    (with-dead-pane (pane)
      (let ((nerimux::*running* nil)
            (nerimux::*dirty*   nil))
        (finishes (nerimux::%pane-reader-loop pane))
        (expect nerimux::*dirty* :to-be-falsy))))

  ;;; ── CPS reader states ────────────────────────────────────────────────────────

  ;; reader-eof-state always returns NIL and stops the reader loop: pane
  ;; 終了時は即座に閉じる (§1.4).  R2.6 removed the remain-on-exit parking
  ;; state (#'reader-remain-on-exit-state) and its banner entirely, so EOF has
  ;; exactly one outcome now, independent of any option.
  (it "reader-eof-state-always-returns-nil"
    (with-dead-pane (pane)
      (expect (null (nerimux::reader-eof-state pane))))))

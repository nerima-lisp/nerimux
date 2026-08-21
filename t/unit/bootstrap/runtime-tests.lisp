(in-package #:nerimux/test)

;;;; global variables, pane-reader-loop, reader EOF, and alert actions

;;; ── Test fixture macros ──────────────────────────────────────────────────────

(defmacro with-dead-pane ((pane-var) &body body)
  "Bind PANE-VAR to a standard dead pane (fd=-1, pid=-1, 5×3 screen) for BODY.
   Eliminates the repeated (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 5 3))
   boilerplate."
  `(let ((,pane-var (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 5 3))))
     ,@body))

(defmacro with-isolated-state (&body body)
  "Run BODY with config isolated (with-isolated-config).  Kept as a thin alias
   so call sites that predate the removal of the hooks subsystem still read
   the same; hooks isolation dropped out with nerimux/hooks."
  `(with-isolated-config
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

  ;; reader-eof-state returns NIL when remain-on-exit is not set.
  (it "reader-eof-state-returns-nil-without-remain-on-exit"
    (with-dead-pane (pane)
      (with-isolated-options ("remain-on-exit" nil)
        (expect (null (nerimux::reader-eof-state pane))))))

  ;; reader-eof-state returns #'reader-remain-on-exit-state when remain-on-exit is set.
  (it "reader-eof-state-returns-remain-state-when-option-set"
    (with-dead-pane (pane)
      (with-isolated-options ("remain-on-exit" t)
        (let ((result (nerimux::reader-eof-state pane)))
          (expect (functionp result))))))

  ;; reader-eof-state honors a PANE-LOCAL remain-on-exit override at
  ;; runtime: with the GLOBAL remain-on-exit NIL but the pane-local value set to
  ;; T, reader-eof-state must return the parking state #'reader-remain-on-exit-state
  ;; (proving runtime.lisp's get-option-for-pane read honors per-pane overrides).
  (it "reader-eof-state-honors-pane-local-remain-on-exit"
    (with-isolated-state
      (let* ((sess (make-fake-session))
             (pane (nerimux/model:session-active-pane sess))
             (nerimux::*dirty* nil))
        (nerimux/options:set-option "remain-on-exit" nil)
        (nerimux/options:set-option-for-pane "remain-on-exit" "on" pane)
        (let ((result (nerimux::reader-eof-state pane)))
          (expect (eq #'nerimux::reader-remain-on-exit-state result))))))

  ;; %remain-on-exit-banner expands remain-on-exit-format and wraps it in
  ;; reverse video; an empty format falls back to the built-in message.
  (it "remain-on-exit-banner-uses-format-option"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 10 3))))
      (with-isolated-options ("remain-on-exit-format" "DEAD")
        (let ((banner (nerimux::%remain-on-exit-banner pane)))
          (expect (search "DEAD" banner))
          (expect (search (format nil "~C[7m" #\Escape) banner))))
      (with-isolated-options ("remain-on-exit-format" "")
        (expect (string= nerimux::+remain-on-exit-message+
                         (nerimux::%remain-on-exit-banner pane))))))

  ;; reader-eof-state writes the remain-on-exit-format banner to the pane
  ;; screen when remain-on-exit is set.
  (it "reader-eof-state-writes-format-banner-to-screen"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 10 3))))
      (with-isolated-options ("remain-on-exit" t "remain-on-exit-format" "BYE")
        (nerimux::reader-eof-state pane)
        (expect (search "BYE" (row-string (pane-screen pane) 0 :end 10)))))))

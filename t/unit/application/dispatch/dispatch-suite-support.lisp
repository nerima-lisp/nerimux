(in-package #:nerimux/test)

;;;; Dispatch test suite and shared support macros.
;;;;
;;;; This file defines no tests of its own — it only provides the shared
;;;; helper macros used by the dispatch-suite family of test files, each of
;;;; which opens its own `(describe "dispatch-suite" ...)` block.  cl-weave
;;;; merges same-named describe blocks across files, so no separate suite
;;;; declaration is needed here.

(defmacro with-copy-mode-active-screen ((session-var screen-var &key feed) &body body)
  "Bind SESSION-VAR and SCREEN-VAR in an active copy-mode session.
   Optional FEED seeds the screen before BODY runs."
  `(with-fake-session (,session-var)
     (nerimux::dispatch-command ,session-var :copy-mode-enter nil)
     (let ((,screen-var (active-screen ,session-var)))
       ,@(when feed `((feed ,screen-var ,feed)))
       ,@body)))

(defmacro with-mocked-respawn-pane ((respawn-mock-var reader-mock-var) &body body)
  "Execute BODY with nerimux/model:respawn-pane and nerimux::start-reader-thread
   replaced by cl-weave mock functions, bound to RESPAWN-MOCK-VAR and
   READER-MOCK-VAR (originals restored automatically on exit via
   cl-weave:with-mocked-functions).  Query call history with
   (mock-calls respawn-mock-var) / (mock-calls reader-mock-var) — each entry
   is the full argument list as called, e.g. for respawn-pane:
   (session pane :start-dir \"...\" :default-command \"...\" :extra-env (...))."
  `(let ((,respawn-mock-var
          (make-mock-function
           (lambda (session pane &key start-dir default-command extra-env)
             (declare (ignore session start-dir default-command extra-env))
             pane)))
         (,reader-mock-var
          (make-mock-function (lambda (pane) (declare (ignore pane))))))
     (with-mocked-functions
         (((fdefinition 'nerimux/model:respawn-pane) ,respawn-mock-var)
          ((fdefinition 'nerimux::start-reader-thread) ,reader-mock-var))
       ,@body)))

(defmacro with-stubbed-switch-to-session ((target-var) &body body)
  "Execute BODY with nerimux::%switch-to-session replaced by a stub that
   records its TARGET argument into TARGET-VAR.  Restores the original
   function via unwind-protect."
  (let ((orig (gensym "ORIG-SWITCH-TO-SESSION")))
    `(let* ((,target-var nil)
            (,orig (fdefinition 'nerimux::%switch-to-session)))
       (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::%switch-to-session)
                   (lambda (target) (setf ,target-var target)))
             ,@body)
         (setf (fdefinition 'nerimux::%switch-to-session) ,orig)))))

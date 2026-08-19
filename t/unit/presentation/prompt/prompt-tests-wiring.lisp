(in-package #:nerimux/test)

;;;; Wiring and display tests split out from prompt-tests.lisp so the base file
;;;; stays focused on prompt state, cursor, and kill/edit behaviour.

(describe "prompt-suite"

  ;;; -- Status-bar display ------------------------------------------------------
  ;;;
  ;;; The handle-prompt-key wiring tests that used to lead this file are gone with
  ;;; handle-prompt-key itself, which was generated in the deleted
  ;;; presentation/events/events-core.lisp.  The workspace UI drives its own
  ;;; command line through server-multi-dispatch, not through that prompt-key
  ;;; pipeline; what survives here is the renderer still showing an active prompt.
  ;; render-status-bar shows the prompt text while a prompt is active.
  (it "status-bar-shows-prompt"
    (let ((sess (make-renderer-test-session 40 10 :content "")))
      (with-clean-prompt
        (prompt-start "rename-window" "foo" (make-noop-submit))
        (let ((out (render-status-bar-output sess 10 40)))
          (expect (search "rename-window: foo" out)))))))

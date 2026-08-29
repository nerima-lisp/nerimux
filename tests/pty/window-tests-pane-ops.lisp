(in-package #:nerimux/pty-test)

;;;; Window-level tests: pane selection and resize behavior.
;;;;
;;;; Moved wholesale from tests/unit/domain/model/window-tests-pane-ops.lisp
;;;; (R9.2): its one case spawns a real PTY-backed session via WITH-SESSION.

(describe "model-suite"

  ;;; ── Splitting and selecting panes ─────────────────────────────────────────

  ;; After a split the first pane can be re-selected as active.
  (it "window-select-pane"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let* ((win        (session-active-window session))
             (first-pane (window-active-pane win)))
        ;; Split left/right (:h) → two panes; active switches to the new one.
        (window-split session win :h)
        (expect (= 2 (length (window-panes win))))
        (expect (not (eq first-pane (window-active-pane win))))
        ;; Select the first pane back.
        (window-select-pane win first-pane)
        (expect (eq first-pane (window-active-pane win))))))

  ;;; resize-pane-table and resize-pane-wrong-axis-is-noop were removed:
  ;;; resize-pane (commands-core.lisp) was deleted along with the other
  ;;; pane/window op helpers.
  )

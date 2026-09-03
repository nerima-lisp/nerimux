(in-package #:nerimux/pty-test)

;;;; window-split wires pane-window on the new pane to the parent window
;;;; (real PTY).
;;;;
;;;; Moved from tests/unit/domain/model/window-tests-c.lisp (R9.2): the one case
;;;; there that spawns a real PTY, via WITH-SESSION.  window-tests-c.lisp's
;;;; other pane-window back-pointer cases verify only the clear path, using
;;;; make-no-pty-pane, and stayed in nerimux/test.
(describe "model-suite"

  ;; window-split wires pane-window on the new pane to the parent window.
  (it "window-split-sets-pane-window-back-pointer"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let* ((win   (session-active-window session))
             (p-new (window-split session win :h)))
        (expect (eq win (pane-window p-new)))))))

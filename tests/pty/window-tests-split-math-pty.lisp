(in-package #:nerimux/pty-test)

;;;; window-split :full refuses root splits that cannot leave both panes at
;;;; min size (real PTY).
;;;;
;;;; Moved from tests/unit/domain/model/window-tests-split-math.lisp.  This case
;;;; was NOT in R9.2's original 11-file audit list -- that list was built by
;;;; grepping for pty-available-p / with-pty-available / forkpty-with-shell,
;;;; and this file's only real-PTY tell is an unqualified (with-session ...)
;;;; call, which none of those three patterns match.  It wraps its
;;;; table-driven body in WITH-SESSION (spawns a real PTY-backed session via
;;;; create-initial-session), unlike every other case in
;;;; window-tests-split-math.lisp, which passes NIL or a hand-built no-PTY
;;;; window/pane and never reaches spawn-pty.
;;;;
;;;; It also had no pty-available-p skip guard in its original location: on a
;;;; sandboxed machine without /dev/ptmx it would have errored rather than
;;;; skipped.  The guard below is new, added here as part of R9.2/R9.3 --
;;;; every other real-PTY case in this suite (and every case that used to
;;;; share a file with it) skips instead of erroring in that situation, and
;;;; there was no reason for this one case to differ.
(describe "model-suite"

  ;; window-split :full refuses root splits that cannot leave both panes at min size.
  (it "window-split-full-obeys-axis-minimums"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (dolist (row '((:h 4 24 "full h-split needs at least 5 columns")
                     (:v 80 2 "full v-split needs at least 3 rows")))
        (destructuring-bind (direction width height desc) row
          (declare (ignore desc))
          (let* ((p0   (make-no-pty-pane 1 0 0 width height))
                 (leaf (make-layout-leaf p0))
                 (win  (make-window :id 1 :name "w" :width width :height height
                                    :panes (list p0)
                                    :tree leaf)))
            (window-select-pane win p0)
            (expect (null (window-split session win direction :full t)))
            (expect (eq leaf (window-tree win)))
            (expect (equal (list p0) (window-panes win)))
            (expect (eq p0 (window-active-pane win)))))))))

(in-package #:nerimux/pty-test)

;;;; PTY integration tests: spawn a real shell over a pseudo-terminal and
;;;; exercise the spawn/write/read/select pipeline end to end.
;;;;
;;;; Moved from t/integration/pty-tests.lisp (R9.2): these are exactly the
;;;; cases from that file that spawn a real PTY (WITH-PTY-SHELL /
;;;; WITH-PTY-AVAILABLE / WITH-SESSION).  The sandbox-safe remainder --
;;;; argument assembly, pipe-fd round-trips, pure constants -- stayed behind
;;;; in nerimux/test.  Every case here still (skip)s rather than fails when
;;;; /dev/ptmx is unavailable, so this suite also runs clean in a sandboxed
;;;; `nix build`/`nix run .#test-pty` -- it just proves nothing there, same as
;;;; before the split.

(describe "pty-suite"

  (it "shell-echoes-command-output"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let ((marker "NERIMUX_MARKER_42"))
        ;; Give the shell a moment to start, then send a command.
        (sleep 0.2)
        (pty-write fd (format nil "echo ~A~%" marker))
        (let ((out (drain-pty fd :stop-marker marker)))
          (expect (search marker out))))))

  (it "pty-write-accepts-octet-vector"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let ((bytes (map '(simple-array (unsigned-byte 8) (*))
                        #'char-code
                        (format nil "printf DONE_OCTETS~%"))))
        (sleep 0.2)
        (pty-write fd bytes)
        (let ((out (drain-pty fd :stop-marker "DONE_OCTETS")))
          (expect (search "DONE_OCTETS" out))))))

  (it "select-times-out-when-idle"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      ;; Drain until two consecutive quiet 200ms windows: certifies the shell has
      ;; truly settled before we test that no further output arrives.
      (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
      (let ((ready (select-fds (list fd) 100000)))  ; 100 ms, no input sent
        (expect (null ready)))))

  ;; Exercises the real resize path: spawned PTY per pane + ioctl(TIOCSWINSZ) +
  ;; screen-resize, across a split and a subsequent terminal resize.
  (it "split-then-relayout-keeps-panes-fitting"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        ;; Split vertically → two panes side by side.
        (window-split session win :h)
        (expect (= 2 (length (window-panes win))))
        ;; Now resize the terminal larger and relayout.
        (window-relayout win 40 120)
        (let ((ps (window-panes win)))
          ;; All panes fit within the new geometry, no overlap.
          (dolist (p ps)
            (expect (<= (+ (pane-x p) (pane-width p))  120))
            (expect (<= (+ (pane-y p) (pane-height p)) 40))
            (expect (plusp (pane-width  p)))
            (expect (plusp (pane-height p))))
          (destructuring-bind (a b) ps
            ;; divider column separates the two panes after relayout
            (expect (< (+ (pane-x a) (pane-width a)) (pane-x b))))))))

  ;; pty-child-exit-status reports KIND = :signaled when the child dies from a
  ;; signal (vs :exited for a normal exit code).  SIGKILL (9) cannot be trapped,
  ;; so the spawned shell is guaranteed to terminate by signal; reaping it via
  ;; pty-child-exit-status must yield (values 9 :signaled).
  (it "pty-child-exit-status-reports-signaled-kind"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (sleep 0.2)
      (sb-posix:kill pid 9)              ; SIGKILL — untrappable
      (multiple-value-bind (code kind) (nerimux/pty:pty-child-exit-status fd)
        (expect (eq kind :signaled))
        (expect (= code 9)))))

  ;;; ── set-pty-size argument order ──────────────────────────────────────────────
  ;;;
  ;;; nerimux's set-pty-size is (MASTER-FD ROWS COLS); cl-tty-kit's
  ;;; set-terminal-size is (COLUMNS ROWS &optional FD). The adapter must both
  ;;; transpose rows/cols AND move the fd. A round-trip on a DELIBERATELY
  ;;; NON-SQUARE size is the only thing that catches an inversion — 24x24 would
  ;;; pass either way. Both dimensions are asserted, so a swap fails loudly.
  ;;;
  ;;; This also covers the arm64 bug this migration fixed: the previous cffi
  ;;; ioctl call used a fixed prototype for a variadic syscall, so on Apple
  ;;; Silicon it returned -1 and the pty kept its old size. Under that code this
  ;;; test reads back the spawn size (8x20), not 40x123, and fails.

  ;; set-pty-size applies rows and columns to the correct fields, not transposed.
  (it "set-pty-size-applies-non-square-size-without-transposition"
    (with-pty-available
      (multiple-value-bind (master pid) (forkpty-with-shell 8 20)
        (unwind-protect
             (progn
               ;; rows=40, cols=123 — distinct, and neither matches the spawn size.
               (nerimux/pty:set-pty-size master 40 123)
               ;; cl-tty-kit:terminal-size returns (values COLUMNS ROWS).
               (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size master)
                 (expect (eql 123 cols))
                 (expect (eql 40 rows))))
          (nerimux/pty:pty-close master pid))))))

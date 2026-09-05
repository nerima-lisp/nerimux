(in-package #:nerimux/pty-test)

(describe "pty-suite"

  (it "shell-echoes-command-output"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let ((marker "NERIMUX_MARKER_42"))
        (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
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
        (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
        (pty-write fd bytes)
        (let ((out (drain-pty fd :stop-marker "DONE_OCTETS")))
          (expect (search "DONE_OCTETS" out))))))

  (it "select-times-out-when-idle"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
      (let ((ready (select-fds (list fd) 100000)))  ; 100 ms, no input sent
        (expect (null ready)))))

  (it "split-then-relayout-keeps-panes-fitting"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        (window-split session win :h)
        (expect (= 2 (length (window-panes win))))
        (window-relayout win 40 120)
        (let ((ps (window-panes win)))
          (dolist (p ps)
            (expect (<= (+ (pane-x p) (pane-width p))  120))
            (expect (<= (+ (pane-y p) (pane-height p)) 40))
            (expect (plusp (pane-width  p)))
            (expect (plusp (pane-height p))))
          (destructuring-bind (a b) ps
            (expect (< (+ (pane-x a) (pane-width a)) (pane-x b))))))))

  (it "pty-child-exit-status-reports-signaled-kind"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
      (sb-posix:kill pid 9)              ; SIGKILL — untrappable
      (multiple-value-bind (code kind) (nerimux/pty:pty-child-exit-status fd)
        (expect (eq kind :signaled))
        (expect (null code)))))


  (it "set-pty-size-applies-non-square-size-without-transposition"
    (with-pty-available
      (multiple-value-bind (master pid) (forkpty-with-shell 8 20)
        (unwind-protect
             (progn
               (nerimux/pty:set-pty-size master 40 123)
               (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size master)
                 (expect (eql 123 cols))
                 (expect (eql 40 rows))))
          (nerimux/pty:pty-close master pid))))))

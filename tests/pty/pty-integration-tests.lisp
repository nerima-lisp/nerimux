(in-package #:nerimux/pty-test)

(describe "pty-suite"

  (it "workspace-agent-stop-reaps-a-child-ignoring-hup"
    (with-pty-available
      (multiple-value-bind (fd pid)
          (forkpty-with-shell 24 80
                              :default-command "trap '' HUP; printf 'STOP_READY\\n'; while :; do :; done")
        (unwind-protect
             (progn
               (expect (search "STOP_READY" (drain-pty fd :stop-marker "STOP_READY")))
               (multiple-value-bind (code kind) (pty-close fd pid)
                 (expect (eq :signaled kind))
                 (expect (eql 9 code)))
               (expect (null (pty-close fd pid)))
               (expect (null (gethash fd nerimux/pty::*pty-processes*))))
          (pty-close fd pid)))))

  #+darwin
  (it "pty-child-owns-session-and-foreground-controlling-terminal"
    (with-pty-available
      (let ((command
              (uiop:escape-shell-command
               (list "exec" (namestring sb-ext:*runtime-pathname*)
                     "--noinform" "--no-sysinit" "--no-userinit"
                     "--non-interactive" "--eval" "(require :sb-posix)"
                     "--eval"
                     "(handler-case
                          (let ((pid (sb-posix:getpid)))
                            (assert (= pid (sb-posix:getsid 0)))
                            (assert (= pid (sb-posix:getpgrp)))
                            (assert (= pid
                                       (sb-alien:alien-funcall
                                        (sb-alien:extern-alien
                                         \"tcgetpgrp\"
                                         (function sb-alien:int sb-alien:int))
                                        0)))
                            (with-open-file (tty \"/dev/tty\" :direction :input)
                              (assert tty)))
                        (error (condition)
                          (format *error-output* \"~A~%\" condition)
                          (sb-ext:exit :code 1)))"))))
        (multiple-value-bind (fd pid)
            (forkpty-with-shell 24 80 :default-command command)
          (unwind-protect
               (multiple-value-bind (code kind) (pty-child-exit-status fd)
                 (expect (eq :exited kind))
                 (expect (eql 0 code)))
            (pty-close fd pid))))))

  (it "shell-echoes-command-output"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let ((marker "NERIMUX_MARKER_42")
            (command (format nil "printf '%s%s\\n' 'NERIMUX_' 'MARKER_42'~%")))
        (expect (null (search marker command)))
        (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
        (pty-write fd command)
        (let ((out (drain-pty fd :stop-marker marker)))
          (expect (search marker out))))))

  (it "pty-write-accepts-octet-vector"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let* ((marker "DONE_OCTETS")
             (command (format nil "printf '%s%s\\n' 'DONE_' 'OCTETS'~%"))
             (bytes (map '(simple-array (unsigned-byte 8) (*))
                         #'char-code command)))
        (expect (null (search marker command)))
        (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
        (pty-write fd bytes)
        (let ((out (drain-pty fd :stop-marker marker)))
          (expect (search marker out))))))

  (it "select-times-out-when-idle"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
      (let ((ready (select-fds (list fd) 100000)))
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
      (sb-posix:kill pid 9)
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

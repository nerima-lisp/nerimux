(in-package #:nerimux/pty-test)

(describe "pty-unit-suite"


  (it "forkpty-with-shell-returns-sane-fd-and-pid"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (expect (>= fd 0))
      (expect (plusp pid))))

  (it "forkpty-with-shell-slave-path-is-a-string"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (multiple-value-bind (fd pid slave-path) (forkpty-with-shell 24 80)
      (unwind-protect
           (expect (string= "" slave-path))
        (pty-close fd pid))))

  (it "set-pty-size-round-trips-non-square-size-on-real-pty"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (finishes (nerimux/pty:set-pty-size fd 30 100)
                "set-pty-size must not signal on a live PTY master fd")
      (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size fd)
        (expect (eql 100 cols))
        (expect (eql 30 rows)))))


  (it "set-pty-size-signals-on-a-zero-dimension"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (signals error (nerimux/pty:set-pty-size fd 0 80))
      (signals error (nerimux/pty:set-pty-size fd 24 0))))


  (it "pty-child-exit-status-times-out-on-a-live-child"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (expect (null (nerimux/pty:pty-child-exit-status
                     fd
                     (cl-date-kit:duration-of-millis 50))))))

  (it "pty-child-exit-status-reports-exited-code"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (multiple-value-bind (fd pid)
        (nerimux/pty:forkpty-with-shell 24 80 :default-command "exit 7")
      (unwind-protect
           (progn
             (multiple-value-bind (code kind) (nerimux/pty:pty-child-exit-status fd)
               (expect (= 7 code))
               (expect (eq :exited kind))))
        (nerimux/pty:pty-close fd pid)))))

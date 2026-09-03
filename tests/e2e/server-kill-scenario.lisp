(defvar *ksc-server-process*
  nil
  "The SB-EXT:PROCESS spawned by SCENARIO-SERVER-STARTS, reused by the later
   kill-* scenarios so SCENARIO-KILL-FORCE-CLEANS can confirm this exact
   process exits.")

(defparameter +ksc-startup-timeout-seconds+
  10
  "Bound for the server socket to appear after SCENARIO-SERVER-STARTS spawns it.")

(defparameter +ksc-shutdown-timeout-seconds+
  10
  "Bound for the server process to exit and its socket to disappear after
   `kill --force`.")

(defparameter +ksc-kill-timeout-seconds+
  10
  "Bound for one `nerimux kill' client invocation to return.")

(defun %ksc-missing-prior-server (scenario-name)
  (values nil
          (format nil
                  "~A: no prior SERVER-STARTS process on record -- ~
                            this group is order-dependent and cannot run alone"
                  scenario-name)))

(defun scenario-kill-without-server (binary)
  "`nerimux kill` with no server running must fail loudly: nonzero exit and
   some diagnostic on stdout/stderr, never a hang."
  (multiple-value-bind (exit-code stdout stderr timed-out) 
      (run-program-bounded binary
                           '("kill")
                           :timeout-seconds
                           +ksc-kill-timeout-seconds+)
    (cond
      (timed-out (values nil "kill hung with no server running"))
      ((null exit-code)
       (values nil "kill returned no exit code (killed by signal?)"))
      ((zerop exit-code)
       (values nil
               (format nil
                       "expected nonzero exit, got 0 (stdout=~S stderr=~S)"
                       stdout
                       stderr)))
      ((and (zerop (length stdout)) (zerop (length stderr)))
       (values nil "expected diagnostic output on stdout/stderr, got none"))
      (t (values t (format nil "exit=~D" exit-code))))))

(defun scenario-server-starts (binary)
  "`nerimux server` (no name argument -> session \"0\") must bind its socket
   within +KSC-STARTUP-TIMEOUT-SECONDS+."
  (setf *ksc-server-process* (spawn-async binary '("server")))
  (let ((socket (%expected-socket-path "0")))
    (if (poll-until
         (lambda ()
           (probe-file socket))
         +ksc-startup-timeout-seconds+)
        (values t (format nil "socket appeared at ~A" socket))
        (values nil
                (format nil
                        "socket ~A never appeared within ~As"
                        socket
                        +ksc-startup-timeout-seconds+)))))

(defun scenario-kill-cleans-empty-server (binary)
  "A plain `nerimux kill` must cleanly stop a server with no open panes.
   The process and its socket must both disappear before the scenario passes."
  (if (null *ksc-server-process*)
      (%ksc-missing-prior-server "kill-cleans-empty-server")
      (multiple-value-bind (exit-code stdout stderr timed-out)
          (run-program-bounded binary
                               '("kill")
                               :timeout-seconds
                               +ksc-kill-timeout-seconds+)
        (declare (ignore stdout))
        (cond
          (timed-out (values nil "plain kill hung"))
          ((not (eql exit-code 0))
           (values nil
                   (format nil
                           "expected exit 0, got ~A (stderr=~S)"
                           exit-code
                           stderr)))
          (t
           (let* ((socket (%expected-socket-path "0"))
                  (process-gone
                   (poll-until
                    (lambda ()
                      (not (sb-ext:process-alive-p *ksc-server-process*)))
                    +ksc-shutdown-timeout-seconds+))
                  (socket-gone
                   (poll-until
                    (lambda ()
                      (not (probe-file socket)))
                    +ksc-shutdown-timeout-seconds+)))
             (if (and process-gone socket-gone)
                 (values t "server process exited and socket removed")
                 (values nil
                         (format nil
                                 "process-gone=~A socket-gone=~A stderr=~S"
                                 (and process-gone t)
                                 (and socket-gone t)
                                 stderr)))))))))

(defun scenario-kill-force-without-server (binary)
  "`nerimux kill --force` must report that no server is running."
  (if (null *ksc-server-process*)
      (%ksc-missing-prior-server "kill-force-without-server")
      (multiple-value-bind (exit-code stdout stderr timed-out)
          (run-program-bounded binary
                               '("kill" "--force")
                               :timeout-seconds
                               +ksc-kill-timeout-seconds+)
        (declare (ignore stdout))
        (cond
          (timed-out (values nil "kill --force hung"))
          ((not (eql exit-code 1))
           (values nil
                   (format nil
                           "expected exit 1, got ~A (stderr=~S)"
                           exit-code
                           stderr)))
          ((search "no server running" stderr)
           (values t (format nil "exit=1 stderr=~S" stderr)))
          (t (values nil
                     (format nil
                             "missing no-server diagnostic (stderr=~S)"
                             stderr)))))))

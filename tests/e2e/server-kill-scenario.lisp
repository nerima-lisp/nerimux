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

(defun %ksc-socket-gone-p ()
  (poll-until
   (lambda ()
     (not (probe-file (%expected-socket-path "0"))))
   +ksc-shutdown-timeout-seconds+))

(defun %ksc-process-gone-p ()
  "True once *KSC-SERVER-PROCESS* has exited, or when no process handle is on
   record: a server auto-started by `attach` belongs to that client, so only
   its socket can be observed from here."
  (or (null *ksc-server-process*)
      (poll-until
       (lambda ()
         (not (sb-ext:process-alive-p *ksc-server-process*)))
       +ksc-shutdown-timeout-seconds+)))

(defun scenario-kill-empty-server-succeeds (binary)
  "A freshly started server holds no pane, so a plain `nerimux kill` must
   exit 0 and take the process and its socket down. Before the workspace
   runtime stopped bootstrapping a hidden shell pane, this same call refused
   with \"panes still open\" on a server nobody had used yet."
  (if (null *ksc-server-process*)
      (%ksc-missing-prior-server "kill-empty-server-succeeds")
      (multiple-value-bind (exit-code stdout stderr timed-out)
          (run-program-bounded binary
                               '("kill")
                               :timeout-seconds
                               +ksc-kill-timeout-seconds+)
        (declare (ignore stdout))
        (cond
          (timed-out (values nil "plain kill hung on an empty server"))
          ((not (eql exit-code 0))
           (values nil
                   (format nil
                           "expected exit 0 on an empty server, got ~A (stderr=~S)"
                           exit-code
                           stderr)))
          (t
           (let ((process-gone (%ksc-process-gone-p))
                 (socket-gone (%ksc-socket-gone-p)))
             (if (and process-gone socket-gone)
                 (values t "empty server exited on plain kill and removed its socket")
                 (values nil
                         (format nil
                                 "process-gone=~A socket-gone=~A stderr=~S"
                                 (and process-gone t)
                                 (and socket-gone t)
                                 stderr)))))))))

(defun scenario-kill-refuses-with-pane (binary)
  "A plain `nerimux kill` must refuse (exit 1) while a pane is open. The pane
   is the one the ATTACH scenario opened in the linked worktree before
   detaching, so this scenario runs after ATTACH. Checking exit=1 alone is not
   sufficient: `nerimux kill` also exits 1 with a \"no reply from server\"
   diagnostic when it cannot reach the server at all (main-startup-commands.lisp
   `t` case), which would false-pass this scenario under a regression that
   broke the pane check. The refusal path's exact diagnostic text is
   \"panes still open\" (main-startup-commands.lisp :DENIED case), so require
   that substring in stderr too."
  (if (not (probe-file (%expected-socket-path "0")))
      (values nil
              "kill-refuses-with-pane: no server socket -- ATTACH must run first")
      (multiple-value-bind (exit-code stdout stderr timed-out)
          (run-program-bounded binary
                               '("kill")
                               :timeout-seconds
                               +ksc-kill-timeout-seconds+)
        (declare (ignore stdout))
        (cond
          (timed-out (values nil "plain kill hung"))
          ((not (eql exit-code 1))
           (values nil
                   (format nil
                           "expected exit 1, got ~A (stderr=~S)"
                           exit-code
                           stderr)))
          ((not (search "panes still open" stderr))
           (values nil
                   (format nil
                           "exit=1 but stderr missing \"panes still open\" (stderr=~S)"
                           stderr)))
          (t (values t (format nil "exit=1 stderr=~S" stderr)))))))

(defun scenario-kill-force-cleans (binary)
  "`nerimux kill --force` must exit 0, then within the deadline the socket
   file must be gone, and so must the server process when its handle is on
   record."
  (if (not (probe-file (%expected-socket-path "0")))
      (values nil "kill-force-cleans: no server socket -- ATTACH must run first")
      (multiple-value-bind (exit-code stdout stderr timed-out)
          (run-program-bounded binary
                               '("kill" "--force")
                               :timeout-seconds
                               +ksc-kill-timeout-seconds+)
        (declare (ignore stdout))
        (cond
          (timed-out (values nil "kill --force hung"))
          ((not (eql exit-code 0))
           (values nil
                   (format nil
                           "expected exit 0, got ~A (stderr=~S)"
                           exit-code
                           stderr)))
          (t
           (let ((process-gone (%ksc-process-gone-p))
                 (socket-gone (%ksc-socket-gone-p)))
             (if (and process-gone socket-gone)
                 (values t "server exited on kill --force and removed its socket")
                 (values nil
                         (format nil
                                 "process-gone=~A socket-gone=~A stderr=~S"
                                 (and process-gone t)
                                 (and socket-gone t)
                                 stderr)))))))))

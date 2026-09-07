(defparameter *e2e-dir*
  (make-pathname :name nil :type nil :defaults *load-truename*)
  "Directory this file was loaded from, used to locate the sibling scenario
   files regardless of the caller's current working directory.")

(defparameter *e2e-repo-root*
  (truename (merge-pathnames "../../" *e2e-dir*))
  "The nerimux checkout root, two directories up from tests/e2e/. Bound before
   attach-scenario.lisp is (lazily) loaded, since it needs this to configure
   ASDF's central registry.")

(load (merge-pathnames "helpers.lisp" *e2e-dir*))

(load (merge-pathnames "server-kill-scenario.lisp" *e2e-dir*))

(defun %run-helper-regressions ()
  (let* ((runtime (namestring (truename sb-ext:*runtime-pathname*)))
         (core (and sb-ext:*core-pathname*
                    (namestring (truename sb-ext:*core-pathname*))))
         (passed 0)
         (failed 0))
    (dolist (name '("bounded-process" "isolation"))
      (handler-case
          (multiple-value-bind (code stdout stderr timed-out)
              (run-program-bounded
               runtime
               (append (list "--noinform")
                       (when (and core (string/= core runtime))
                         (list "--core" core))
                       (list "--no-sysinit" "--no-userinit" "--script"
                             (namestring
                              (truename
                               (merge-pathnames
                                (format nil "~A-tests.lisp" name) *e2e-dir*))))))
            (write-string stdout)
            (write-string stderr *error-output*)
            (let* ((expected (format nil "[~A] 4 selected, 4 passed, 0 failed" name))
                   (summaries
                     (with-input-from-string (stream stdout)
                       (loop for line = (read-line stream nil nil)
                             while line count (string= line expected)))))
              (unless (and (eql code 0) (not timed-out) (= summaries 1))
                (error "exit=~S timeout=~S matching-summaries=~D (expected 1)"
                       code timed-out summaries)))
            (incf passed))
        (error (condition)
          (incf failed)
          (format *error-output* "~&[e2e helpers] FAIL ~A -- ~A~%" name condition)))
      (finish-output)
      (finish-output *error-output*))
    (format t "~&[e2e helpers] ~D verified tests, ~D passed suites, ~D failed suites~%"
            (* 4 passed) passed failed)
    (finish-output)
    (zerop failed)))

(defparameter *scenarios*
  (list (cons "kill-without-server" 'scenario-kill-without-server)
        (cons "server-starts" 'scenario-server-starts)
        (cons "kill-cleans-empty-server" 'scenario-kill-cleans-empty-server)
        (cons "kill-force-without-server" 'scenario-kill-force-without-server)
        (cons "attach" :attach))
  "Mode-name -> handler-symbol (or :ATTACH), in the fixed run order.")

(defun %run-attach-scenario-lazily (binary)
  "Load attach-scenario.lisp and run RUN-ATTACH-SCENARIO, catching any error
   -- including a load failure -- so it reports as a FAIL for this one
   scenario rather than aborting the whole run."
  (handler-case (progn
                  (load (merge-pathnames "attach-scenario.lisp" *e2e-dir*))
                  (funcall (find-symbol "RUN-ATTACH-SCENARIO") binary))
    ((or error sb-ext:timeout) (c)
      (let ((*print-circle* t))
        (values nil (format nil "attach scenario failed to load or run: ~A" c))))))

(defun %run-one-scenario (name binary)
  (let ((entry (cdr (assoc name *scenarios* :test #'string=))))
    (handler-case (if (eq entry :attach)
                      (%run-attach-scenario-lazily binary)
                      (funcall entry binary))
      ((or error sb-ext:timeout) (c)
        (let ((*print-circle* t))
          (values nil (format nil "signalled ~A" c)))))))

(defun %selected-scenario-names (filter-args)
  "All scenario names in order when FILTER-ARGS is empty, else the subset of
   *SCENARIOS* named in FILTER-ARGS, still in *SCENARIOS*'s fixed order."
  (if (null filter-args)
      (mapcar #'car *scenarios*)
      (remove-if-not
       (lambda (n)
         (member n filter-args :test #'string=))
       (mapcar #'car *scenarios*))))

(defparameter +ksc-reap-timeout-seconds+
  5
  "Bound for confirming *KSC-SERVER-PROCESS* has exited during RUN-E2E's
   unconditional post-loop reap.")

(defun %reap-server-process ()
  "Unconditionally SIGKILL and confirm exit of *KSC-SERVER-PROCESS* (defined
   in server-kill-scenario.lisp). A spawned `nerimux server` outlives this process
   whenever SERVER-STARTS times out or KILL-FORCE-CLEANS fails to confirm
   exit; this reap runs regardless of which scenarios passed or failed. A
   no-op when the process is nil or already exited."
  (when (and *ksc-server-process* (sb-ext:process-alive-p *ksc-server-process*))
    (ignore-errors (sb-ext:process-kill *ksc-server-process* 9))
    (unless (poll-until
             (lambda ()
               (not (sb-ext:process-alive-p *ksc-server-process*)))
             +ksc-reap-timeout-seconds+)
      (error "E2E server process survived cleanup"))))

(defparameter +ksc-attach-kill-timeout-seconds+
  10
  "Bound for the `kill --force' RUN-E2E issues to clean up whatever server
   the attach scenario auto-started and left running.")

(defun %reap-attach-server (binary names)
  "Request server shutdown and confirm socket removal, not process exit."
  (when (and (member "attach" names :test #'string=)
             (probe-file (%expected-socket-path "0")))
    (multiple-value-bind (code stdout stderr timed-out)
        (run-program-bounded binary '("kill" "--force")
                             :timeout-seconds +ksc-attach-kill-timeout-seconds+)
      (declare (ignore stdout))
      (unless (and (eql code 0) (not timed-out))
        (error "E2E attach cleanup failed: exit=~S timeout=~S stderr=~S"
               code timed-out stderr)))
    ;; Auto-start discards its process handle; unlink is not proof of exit.
    (unless (poll-until (lambda () (not (probe-file (%expected-socket-path "0"))))
                        +ksc-reap-timeout-seconds+)
      (error "E2E attach socket survived cleanup"))))

(defun %cleanup-e2e-servers (binary names)
  (let ((failures nil))
    (dolist (cleanup (list (lambda () (%reap-attach-server binary names))
                          #'%reap-server-process))
      (handler-case (funcall cleanup)
        (error (condition) (push condition failures))))
    (when failures
      (error "E2E server cleanup failed: ~{~A~^; ~}" failures))))

(defun run-e2e (binary filter-args)
  "Run the selected scenarios against BINARY in order, printing one PASS/FAIL
   line per scenario and a summary after successful cleanup. Cleanup errors
   propagate without a summary. Returns 0 only when at least one scenario
   was selected, every selected scenario passed, and both helper suites passed."
  (let* ((names (%selected-scenario-names filter-args))
         (passed 0)
         (failed 0)
         (helpers-passed nil))
    (call-with-isolated-e2e-environment
     (lambda (root)
       (declare (ignore root))
       (setf *ksc-server-process* nil)
       (setf helpers-passed (%run-helper-regressions))
       (dolist (name names)
         (multiple-value-bind (ok detail) (%run-one-scenario name binary)
           (format t "~&[e2e] ~:[FAIL~;PASS~] ~A -- ~A~%" ok name detail)
           (finish-output)
           (if ok
               (incf passed)
               (incf failed)))))
     :cleanup (lambda (root)
                (declare (ignore root))
                (%cleanup-e2e-servers binary names)))
    (format t
            "~&[e2e] ~D selected, ~D passed, ~D failed~%"
            (length names)
            passed
            failed)
    (finish-output)
    (if (and helpers-passed (plusp (length names)) (zerop failed)) 0 1)))

(let ((binary (or (second sb-ext:*posix-argv*) "result/bin/nerimux"))
      (filters (nthcdr 2 sb-ext:*posix-argv*)))
  (sb-ext:exit :code
               (handler-case (run-e2e binary filters)
                 (error (condition)
                   (format *error-output* "~&[e2e] FAIL harness -- ~A~%" condition)
                   1))))

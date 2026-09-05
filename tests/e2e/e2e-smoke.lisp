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
   in server-kill-scenario.lisp, loaded eagerly by this file before RUN-E2E
   is ever called). A spawned `nerimux server` outlives this process
   whenever SERVER-STARTS times out or KILL-FORCE-CLEANS fails to confirm
   exit; this reap runs regardless of which scenarios passed or failed. A
   no-op when the process is nil or already exited."
  (when (and *ksc-server-process* (sb-ext:process-alive-p *ksc-server-process*))
    (ignore-errors (sb-ext:process-kill *ksc-server-process* 9))
    (poll-until
     (lambda ()
       (not (sb-ext:process-alive-p *ksc-server-process*)))
     +ksc-reap-timeout-seconds+)))

(defparameter +ksc-attach-kill-timeout-seconds+
  10
  "Bound for the `kill --force' RUN-E2E issues to clean up whatever server
   the attach scenario auto-started and left running.")

(defun %reap-attach-server (binary names)
  "When \"attach\" was among the selected scenario NAMES, issue `BINARY kill
   --force' to clean up whatever server RUN-ATTACH-SCENARIO auto-started
   (attach-scenario.lisp): attach detaches without killing, by design --
   the server is meant to persist for reattachment -- so nothing else in
   this file's control flow ever stops it. This reuses the product's own
   cleanup path rather than tracking the attach scenario's server pid.
   A \"no reply from server\" failure (nonzero exit, no crash) is expected
   and ignored whenever the attach scenario never got far enough to start
   a server, or something else already cleaned it up."
  (when (member "attach" names :test #'string=)
    (ignore-errors
     (run-program-bounded binary
                          '("kill" "--force")
                          :timeout-seconds
                          +ksc-attach-kill-timeout-seconds+))))

(defun run-e2e (binary filter-args)
  "Run the selected scenarios against BINARY in order, printing one PASS/FAIL
   line per scenario, then a summary line. Exits 0 only when at least one
   scenario was selected and every selected scenario passed -- a selection
   matching nothing is a FAIL, not a vacuous pass."
  (let* ((names (%selected-scenario-names filter-args))
         (passed 0)
         (failed 0))
    (dolist (name names)
      (multiple-value-bind (ok detail) (%run-one-scenario name binary)
        (format t "~&[e2e] ~:[FAIL~;PASS~] ~A -- ~A~%" ok name detail)
        (finish-output)
        (if ok
            (incf passed)
            (incf failed))))
    (%reap-server-process)
    (%reap-attach-server binary names)
    (format t
            "~&[e2e] ~D selected, ~D passed, ~D failed~%"
            (length names)
            passed
            failed)
    (finish-output)
    (sb-ext:exit :code
                 (if (and (plusp (length names)) (zerop failed))
                     0
                     1))))

(let ((binary (or (second sb-ext:*posix-argv*) "result/bin/nerimux"))
      (filters (nthcdr 2 sb-ext:*posix-argv*)))
  (run-e2e binary filters))

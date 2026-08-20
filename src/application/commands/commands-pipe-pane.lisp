(in-package #:nerimux/commands)

;;; ── pipe-pane ───────────────────────────────────────────────────────────────
;;;
;;; pipe_pane(Pane, Cmd) :-
;;;   (existing_pipe(Pane) -> close_pipe(Pane) ; true),
;;;   (Cmd \= nil -> open_pipe(Pane, Cmd) ; true).

(defconstant +pipe-pane-close-timeout+ 1
  "Seconds to wait for a pipe-pane subprocess to exit after stdin closes.")

(defconstant +pipe-pane-open-timeout+ 1
  "Seconds to wait for launching the pipe-pane subprocess.")

(defmacro %with-timeout-cleanup ((timeout-seconds cleanup-thunk) &body body)
  "Run BODY under a TIMEOUT-SECONDS CL-CONCURRENT-KIT:WITH-TIMEOUT.  On success,
   return BODY's value.  On an OPERATION-TIMED-OUT or any other error, funcall
   CLEANUP-THUNK (a zero-argument function) and return NIL.  Consolidates the
   'run with a deadline, clean up identically on either failure kind, else fall
   through to NIL' shape shared by the pipe-pane launch/wait sites.

   The deadline is a bare form, not (,TIMEOUT-SECONDS): cl-concurrent-kit's
   WITH-TIMEOUT follows SB-EXT:WITH-TIMEOUT's shape rather than bordeaux-threads'."
  `(handler-case
       (cl-concurrent-kit:with-timeout ,timeout-seconds ,@body)
     ((or cl-concurrent-kit:operation-timed-out error) ()
       (funcall ,cleanup-thunk)
       nil)))

(defun %pipe-pane-copy-output (pane output-stream)
  "Copy OUTPUT-STREAM from the command back into PANE's PTY."
  (unwind-protect
      (handler-case
          (let ((buffer (make-string 4096)))
            (loop
              for count = (read-sequence buffer output-stream)
              while (plusp count) do
                (ignore-errors
                  (nerimux/ports:write-pty (pane-fd pane)
                                           (subseq buffer 0 count)))))
        ((or end-of-file error) () nil))
    (ignore-errors (close output-stream))))

(defun %pipe-pane-start-output-thread (pane output-stream)
  "Start the background copier for command stdout into PANE."
  (cl-concurrent-kit:make-thread
   (lambda () (%pipe-pane-copy-output pane output-stream))
   :name (format nil "pipe-pane-output-~D" (pane-id pane))))

(defun %pipe-pane-reset (pane)
  "Clear all pipe-pane state slots on PANE."
  (setf (pane-pipe-fd pane) nil
        (pane-pipe-output-stream pane) nil
        (pane-pipe-output-thread pane) nil
        (pane-pipe-process pane) nil))

(defun pipe-pane-open (pane command &key
                            (pane-output-to-command-p t)
                            (command-output-to-pane-p nil))
  "Connect PANE and COMMAND with pipe-pane direction flags.
   PANE-OUTPUT-TO-COMMAND-P routes pane output to the command's stdin.
   COMMAND-OUTPUT-TO-PANE-P routes command stdout back into the pane.
   Returns a non-NIL stream or process handle on success, NIL on failure."
  ;; Close any existing pipe in either direction.
  (when (pane-pipe-active-p pane)
    (pipe-pane-close pane))
  (let ((proc nil)
        (input-stream nil)
        (output-stream nil)
        (output-thread nil))
    (%with-timeout-cleanup
        (+pipe-pane-open-timeout+
         (lambda ()
           (%pipe-pane-cleanup pane
                               :input-stream input-stream
                               :output-stream output-stream
                               :output-thread output-thread
                               :process proc)))
      (let* ((shell (or nerimux/config:*default-shell* "/bin/sh"))
             (new-proc
               ;; :search t is required, not optional.  process-kit:spawn defaults
               ;; :search to NIL and passes that straight to run-program, so a
               ;; bare shell name never resolves on PATH.  Unlike the two
               ;; /bin/sh literals elsewhere in this repo, SHELL here comes from
               ;; *default-shell*, which init-default-shell fills from $SHELL and
               ;; the `set-shell` directive accepts unvalidated.  Same reasoning
               ;; as format-context-os-probe.lisp:38-40.
               ;;
               ;; :environment is likewise required, not optional.  process-kit:spawn
               ;; forwards ENVIRONMENT straight to SB-EXT:RUN-PROGRAM's :environment,
               ;; and SBCL treats an *explicit* NIL there as "run with an empty
               ;; environment", not "inherit" -- inheritance only happens when the
               ;; keyword is left out entirely.  spawn's own &key list always supplies
               ;; the keyword (defaulting to NIL), so every other call site in this
               ;; repo (pty.lisp, pane-spawn.lisp, pty-port.lisp) threads an explicit
               ;; environment through for exactly this reason.  Without it here, COMMAND
               ;; runs under SHELL with $PATH unset, so a bare command name (`cat`,
               ;; anything not given as an absolute path) fails to resolve inside the
               ;; child shell -- silently, since :error is nil below.
               (process-kit:spawn shell (list "-c" command)
                                  :search t
                                  :environment (sb-ext:posix-environ)
                                  :input (if pane-output-to-command-p :stream nil)
                                  :output (if command-output-to-pane-p :stream nil)
                                  :error nil))
             (new-input (and pane-output-to-command-p
                             (process-kit:process-stdin new-proc)))
             (new-output (and command-output-to-pane-p
                              (process-kit:process-output new-proc))))
        (setf proc new-proc
              input-stream new-input
              output-stream new-output
              (pane-pipe-fd pane) input-stream
              (pane-pipe-output-stream pane) output-stream
              (pane-pipe-process pane) proc)
        (when output-stream
          (setf output-thread
                (%pipe-pane-start-output-thread pane output-stream)
                (pane-pipe-output-thread pane) output-thread))
        (or input-stream output-stream proc t)))))

(defun %wait-pipe-process (process)
  "Return true when PROCESS exits before the pipe-pane close timeout."
  (when process
    (%with-timeout-cleanup (+pipe-pane-close-timeout+ (constantly nil))
      (process-kit:process-wait process)
      t)))

(defun %terminate-pipe-process (process)
  "Reap a pipe-pane subprocess, terminating it only if it ignores stdin EOF."
  (when (and process (not (%wait-pipe-process process)))
    (ignore-errors
      (when (process-kit:process-alive-p process)
        (process-kit:process-terminate process)))
    (%wait-pipe-process process)))

(defun %pipe-pane-cleanup (pane &key input-stream output-stream output-thread process)
  "Best-effort cleanup for pipe-pane resources, then reset PANE."
  (when input-stream
    (ignore-errors (close input-stream)))
  (when output-stream
    (ignore-errors (close output-stream)))
  (ignore-errors (%terminate-pipe-process process))
  (when output-thread
    (ignore-errors
      (nerimux::%join-thread-with-timeout output-thread
                                          +pipe-pane-close-timeout+)))
  (%pipe-pane-reset pane))

(defun pipe-pane-close (pane)
  "Close PANE's output pipe if one is open."
  (%pipe-pane-cleanup pane
                      :input-stream (pane-pipe-fd pane)
                      :output-stream (pane-pipe-output-stream pane)
                      :output-thread (pane-pipe-output-thread pane)
                      :process (pane-pipe-process pane)))

(defun pipe-pane-write (pane bytes)
  "Write BYTES to PANE's output pipe if one is active.
   Silently ignores write errors (pipe may have closed on the other end)."
  (when (pane-pipe-fd pane)
    (ignore-errors
      (write-sequence bytes (pane-pipe-fd pane))
      (force-output (pane-pipe-fd pane)))))

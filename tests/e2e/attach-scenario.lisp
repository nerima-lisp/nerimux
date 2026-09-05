(%configure-asdf-registry *e2e-repo-root*)

(asdf:load-system :nerimux)

(use-package :nerimux/pty)

(defconstant +e2e-startup-timeout-seconds+
  8
  "Maximum seconds to wait for nerimux and its inner shell to initialize before typing.")

(defconstant +e2e-startup-quiet-seconds+
  0.5
  "Seconds of quiet PTY output after first render before typing the marker command.")

(defconstant +e2e-marker-timeout-seconds+
  6
  "Maximum seconds to wait for the marker to appear in the rendered output.")

(defconstant +e2e-detach-timeout-seconds+
  3
  "Maximum seconds to wait for nerimux to exit after the detach key.")

(defconstant +e2e-exit-wait-poll-millis+
  200
  "Per-iteration PTY-CHILD-EXIT-STATUS timeout inside
   %WAIT-FOR-CHILD-EXIT-DRAINING, in milliseconds (CL-DATE-KIT:DURATION-OF-
   SECONDS only accepts an integer, so a sub-second poll interval needs the
   millisecond constructor instead). Short so the loop keeps returning to
   drain the PTY between exit-status checks, rather than parking in one
   long PROCESS-WAIT the way the bare call used to.")

(defconstant +e2e-poll-timeout-us+
  nerimux/ports:+poll-timeout-us+
  "Select timeout in microseconds when polling the PTY for output.")

(defconstant +e2e-read-buf-size+
  nerimux/ports:+pty-buf-size+
  "PTY read buffer size in bytes.")

(defconstant +e2e-search-window-bytes+
  (* 64 1024)
  "Maximum recent PTY output bytes to scan for the marker.")

(defun %wait-for-marker (fd substr seconds acc)
  "Poll FD for PTY output up to SECONDS, accumulating into ACC.
   Returns T when SUBSTR appears in the output, NIL on timeout."
  (let ((deadline
         (+ (get-internal-real-time) (* seconds internal-time-units-per-second)))
        (mlen (length substr)))
    (loop (when (> (get-internal-real-time) deadline)
            (return nil)) (when (select-fds (list fd) +e2e-poll-timeout-us+)
                            (let ((chunk
                                   (pty-read-blocking-into fd
                                                           (make-array
                                                            +e2e-read-buf-size+
                                                            :element-type
                                                            '(unsigned-byte 8)))))
                              (when chunk
                                (%accumulate-chunk acc chunk)
                                (when 
                                    (%search-in-tail substr
                                                     acc
                                                     (max
                                                      +e2e-search-window-bytes+
                                                      mlen))
                                  (return t))))))))

(defun %wait-for-startup-render (fd seconds acc)
  "Poll FD until nerimux has rendered at least once and output has gone quiet.
   The integration smoke drives the built binary, whose startup time varies
   enough that a fixed sleep can type before raw mode and the first pane are ready."
  (let ((deadline
         (+ (get-internal-real-time) (* seconds internal-time-units-per-second)))
        (quiet-ticks
         (* +e2e-startup-quiet-seconds+ internal-time-units-per-second))
        (last-output nil))
    (loop (let ((now (get-internal-real-time)))
            (when (> now deadline)
              (return (not (null last-output))))
            (when (and last-output (>= (- now last-output) quiet-ticks))
              (return t))) (when (select-fds (list fd) +e2e-poll-timeout-us+)
                             (let ((chunk
                                    (pty-read-blocking-into fd
                                                            (make-array
                                                             +e2e-read-buf-size+
                                                             :element-type
                                                             '(unsigned-byte 8)))))
                               (when chunk
                                 (%accumulate-chunk acc chunk)
                                 (setf last-output (get-internal-real-time))))))))

(defun %wait-for-child-exit-draining (fd seconds acc)
  "Poll FD for up to SECONDS, draining any output into ACC, while
   repeatedly checking for the child's exit status. Returns (VALUES
   exit-code exit-kind), the same shape PTY-CHILD-EXIT-STATUS returns, or
   (VALUES NIL NIL) on timeout.

   A detaching client can still be mid-teardown (alt-screen exit, cursor
   restore, status line) when the detach key is sent. A bare, undrained
   PTY-CHILD-EXIT-STATUS call here previously deadlocked: nothing read the
   PTY after detach, so that teardown output filled the kernel PTY buffer
   and the child blocked forever inside its own WRITE(2), which
   PTY-CHILD-EXIT-STATUS's PROCESS-WAIT can never observe an exit from.
   Confirmed live via `sample` on the stuck child: 100% of samples showed
   its main thread parked in WRITE. Keeping the drain going here, alongside
   the exit check, lets that write complete."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (when (> (get-internal-real-time) deadline) (return (values nil nil)))
      (when (select-fds (list fd) +e2e-poll-timeout-us+)
        (let ((chunk (pty-read-blocking-into fd (make-array +e2e-read-buf-size+ :element-type '(unsigned-byte 8)))))
          (when chunk (%accumulate-chunk acc chunk))))
      (multiple-value-bind (exit-code exit-kind)
          (pty-child-exit-status
           fd (cl-date-kit:duration-of-millis +e2e-exit-wait-poll-millis+))
        (when exit-kind
          (return (values exit-code exit-kind)))))))

(defun run-attach-scenario (binary)
  "Drive BINARY through `attach` -> type a marker -> detach. Returns
   (VALUES pass-p detail-string); never calls SB-EXT:EXIT, so the caller
   controls the process's overall exit status."
  (format t "~&[e2e] driving ~A~%" binary)
  (multiple-value-bind (fd pid)
      (forkpty-with-shell 24 80
                          :default-command (format nil "exec ~S attach" binary)
                          :environment (sb-ext:posix-environ))
    (unwind-protect
         (let ((marker "E2E_PROOF_4242")
               (acc    (%make-accumulator)))
           (%wait-for-startup-render fd +e2e-startup-timeout-seconds+ acc)
           (pty-write fd (make-array 1 :element-type '(unsigned-byte 8)
                                      :initial-contents (list (char-code #\q))))
           (pty-write fd (format nil "echo ~A~%" marker))
           (let ((found (%wait-for-marker fd marker +e2e-marker-timeout-seconds+ acc)))
             (pty-write fd (make-array 2 :element-type '(unsigned-byte 8)
                                          :initial-contents (list 17 (char-code #\d))))
             (multiple-value-bind (exit-code exit-kind)
                 (%wait-for-child-exit-draining fd +e2e-detach-timeout-seconds+ acc)
               (if (and found (eq :exited exit-kind) (zerop exit-code))
                   (values t "marker rendered and nerimux exited cleanly")
                   (values nil
                           (format nil "marker=~A exit-kind=~A exit-code=~A captured=~D bytes"
                                   (if found :found :missing) exit-kind exit-code
                                   (fill-pointer acc)))))))
      (pty-close fd pid))))

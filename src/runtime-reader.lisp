(in-package #:nerimux)


(defun %pane-retired-p (pane)
  "True once PANE's fd has been cleared, which is this loop's ONLY per-pane
   stop signal.

   %RUN-READER-STATES loops on the global *RUNNING*, so STOP-READER-THREADS is
   a whole-server shutdown; nothing else ever told a single pane's reader to
   stop.  Without this check the loop is not merely leaked but actively
   harmful, because SELECT-FDS maps a closed descriptor's EBADF to NIL by
   design (see its docstring in infrastructure/pty/pty.lisp: turning that race
   into a signal would take the serve loop down).  For the serve loop that is
   right; for this loop it means a retired pane polls a dead fd every 50ms
   forever, and then acts on whatever the OS later assigns that number.
   RETIRE-PANE-PTY publishes the -1 before closing so this check wins the
   race."
  (not (plusp (pane-fd pane))))

(defun reader-idle-state (pane)
  "Poll the pane PTY fd; transition to reading if data is available, or stop
   when PANE has been retired underneath this thread."
  (cond
    ((%pane-retired-p pane) nil)
    ((select-fds (list (pane-fd pane)) +pty-poll-timeout-us+)
     #'reader-reading-state)
    (t #'reader-idle-state)))

(defun reader-reading-state (pane)
  "Read one PTY chunk and feed it to PANE; transition to eof if EOF.

   Re-checks retirement because the fd can be cleared between the SELECT-FDS
   that reported it readable and this read."
  (when (%pane-retired-p pane)
    (return-from reader-reading-state nil))
  (let ((bytes (pty-read-blocking-into (pane-fd pane) *reader-scratch-buffer*)))
    (if (null bytes)
        #'reader-eof-state
        (progn
          (handler-case (pane-feed pane bytes)
            (peer-io-failure () nil))
          (nerimux/pane:pane-mark-output pane bytes)
          (when (find 7 bytes)
            (nerimux/pane:pane-mark-bell pane))
          (%mark-dirty)
          #'reader-idle-state))))

(defun reader-eof-state (pane)
  "Close PANE's PTY when it reaches EOF and stop the reader loop immediately —
   pane 終了時は即座に閉じる (§1.4): there is no dead-pane banner and no
   parking state to return to."
  (when (> (pane-fd pane) 0)
    (multiple-value-bind (code kind)
        (nerimux/pty:pty-child-exit-status (pane-fd pane))
      (nerimux/pane:pane-mark-process-exit
       pane
       :status (and (eq kind :exited) code)
       :signal (and (eq kind :signaled) code)))
    (close-pane-pty pane)
    (setf (pane-fd pane) -1
          (pane-pid pane) -1))
  (%mark-dirty)
  nil)

(defun %run-reader-states (pane initial-state)
  "Drive the CPS reader state machine for PANE starting from INITIAL-STATE."
  (loop for state = initial-state then (funcall state pane)
        while (and *running* state)))

(defun %pane-reader-loop (pane)
  "Feed PTY output into PANE screen until EOF or *running* becomes NIL."
  (let ((*reader-scratch-buffer*
          (make-array +pty-buf-size+ :element-type '(unsigned-byte 8))))
    (%run-reader-states pane #'reader-idle-state)))

(defun start-reader-thread (pane)
  "Spawn a thread running %pane-reader-loop for PANE."
  (make-thread
   (lambda ()
     (%pane-reader-loop pane))
   :name
   (format nil "pty-reader-~D" (pane-id pane))))

(defun stop-reader-threads (threads)
  "Signal shutdown and join each thread in THREADS with a bounded timeout."
  (setf *running* nil)
  (dolist (thread threads)
    (handler-case (%join-thread-with-timeout thread
                                             +reader-thread-join-timeout+)
      (sb-thread:join-thread-error ()
        nil))))

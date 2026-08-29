(in-package #:nerimux)

;;;; PTY reader thread — CPS state machine.
;;;;
;;;; This file contains the per-pane I/O thread and state machine.  It is
;;;; loaded after runtime.lisp (shared state, channel sync).
;;;;
;;;; Threading model recap:
;;;;   * One reader thread per pane: blocking read(PTY fd) -> pane-feed ->
;;;;     screen update -> sets *dirty* T.
;;;;   * Main thread: select(stdin, 50 ms) -> key dispatch -> render when dirty.

;;; -- PTY reader thread -------------------------------------------------------
;;;
;;; CPS state machine: each state function takes (pane) and returns the next
;;; state function (or NIL to stop).

(defvar *reader-scratch-buffer* nil
  "Per-reader-thread scratch octet buffer reused by reader-reading-state to read
   one PTY chunk without allocating a fresh +pty-buf-size+ buffer on every read.
   Bound (thread-locally) around each reader loop in %pane-reader-loop, so each
   pane's reader thread owns a distinct buffer.  pty-read-blocking-into returns a
   fresh exact-size copy of the bytes read, so handing that copy downstream is
   safe even though the scratch buffer is overwritten by the next read.")

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
          ;; PANE-FEED is not just a screen update: after processing the bytes
          ;; it drains the device-report queue (DA1/DA2/CPR/DSR/DECRQM/
          ;; XTGETTCAP/DECRQSS/OSC-colour) back to the PTY through WRITE-PTY,
          ;; i.e. PTY-WRITE -- which is bounded by SB-EXT:WITH-TIMEOUT and so
          ;; can signal SB-EXT:TIMEOUT when the pane's child has stopped
          ;; draining its input (SIGTSTP'd, wedged) for longer than
          ;; +PTY-WRITE-TIMEOUT-SECONDS+.
          ;;
          ;; This runs on a per-pane reader THREAD, and an unhandled condition
          ;; on a non-main thread does not merely kill that thread: under
          ;; --disable-debugger SBCL prints "unhandled condition in
          ;; --disable-debugger mode, quitting" and the WHOLE PROCESS exits.
          ;; Verified directly with a two-thread probe -- the main thread's
          ;; scheduled output never ran.  One pane whose child stopped reading
          ;; would therefore disconnect every client on every pane.
          ;;
          ;; Contained rather than propagated: a device-report reply that
          ;; cannot be delivered is not worth a reader thread, let alone the
          ;; server.  The pane keeps its screen state and the loop continues;
          ;; a genuinely dead pane still reaches READER-EOF-STATE by its read
          ;; returning NIL.
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
  ;; The child has exited and the master fd is now at EOF.  Mark the pane DEAD:
  ;; close the master fd (nothing else closes it here — a leak otherwise) and
  ;; reset pane-fd/pane-pid to -1.  #{pane_dead} keys on (<= pane-fd 0)
  ;; (format.lisp), and respawn-pane (without -k) is gated on the pane being
  ;; dead — both were wrong because the reader never reset the fd.  Resetting
  ;; pane-pid too prevents a later teardown (e.g. %destroy-session) from
  ;; re-signalling a stale (possibly OS-reused) pid; respawn-pane re-establishes
  ;; both slots.  pty-close guards non-positive fd/pid, so no-PTY panes (fd -1)
  ;; are an untouched no-op.
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
  ;; Allocate ONE scratch read buffer for this reader thread (one thread per
  ;; pane) and bind it thread-locally for reader-reading-state to reuse, so the
  ;; hot read path no longer allocates a +pty-buf-size+ buffer per read.
  (let ((*reader-scratch-buffer*
          (make-array +pty-buf-size+ :element-type '(unsigned-byte 8))))
    (%run-reader-states pane #'reader-idle-state)))

(defun start-reader-thread (pane)
  "Spawn a thread running %pane-reader-loop for PANE."
  (make-thread (lambda () (%pane-reader-loop pane))
               :name (format nil "pty-reader-~D" (pane-id pane))))

(defun stop-reader-threads (threads)
  "Signal shutdown and join each thread in THREADS with a bounded timeout."
  (setf *running* nil)
  (dolist (thread threads)
    (handler-case
        (%join-thread-with-timeout thread +reader-thread-join-timeout+)
      (sb-thread:join-thread-error () nil))))

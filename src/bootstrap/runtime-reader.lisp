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

(defun reader-idle-state (pane)
  "Poll the pane PTY fd; transition to reading if data is available."
  (if (select-fds (list (pane-fd pane)) +pty-poll-timeout-us+)
      #'reader-reading-state
      #'reader-idle-state))

(defun reader-reading-state (pane)
  "Read one PTY chunk and feed it to PANE; transition to eof if EOF."
  (let ((bytes (pty-read-blocking-into (pane-fd pane) *reader-scratch-buffer*)))
    (if (null bytes)
        #'reader-eof-state
        (progn
          (pane-feed pane bytes)
          (nerimux/model:pane-mark-output pane bytes)
          (when (find 7 bytes)
            (nerimux/model:pane-mark-bell pane))
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
      (nerimux/model:pane-mark-process-exit
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

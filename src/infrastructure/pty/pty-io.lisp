(in-package #:cl-tmux/pty)

;;;; PTY master I/O and port registration.
;;;;
;;;; The lifecycle and terminal-geometry operations stay in pty.lisp.  This
;;;; file owns the byte path and the select(2) boundary so each responsibility
;;;; can be tested without loading unrelated PTY process code.

;;; -- Public: PTY byte I/O --------------------------------------------------

(defun pty-write (fd data)
  "Write DATA (octet vector or UTF-8 string) to the PTY master fd."
  (etypecase data
    (string
     (pty-write fd (cl-codec-kit:string-to-octets data :encoding :utf-8)))
    ((simple-array (unsigned-byte 8) (*))
     ;; Two noop guards preserving the prior raw-write(2) behavior:
     ;;   * empty vector - no write is issued (tests assert this).
     ;;   * negative fd - the "no PTY / dead pane" sentinel (pane-fd -1).  The
     ;;     former CFFI write(2) ignored its return value, so a write to fd -1
     ;;     silently failed; cl-tty-kit's fd-write-octets instead asserts a
     ;;     non-negative fd and signals, so we skip it here.  Real PTY master fds
     ;;     are always positive, and the domain already gates real writes on
     ;;     (> (pane-fd pane) 0).
     (when (and (>= fd 0) (plusp (length data)))
       (cl-tty-kit:fd-write-octets fd data)))))

(defun pty-read-blocking-into (fd buffer)
  "Block until data arrives on FD, read into the caller-supplied octet BUFFER, and
   return a fresh exact-size octet vector holding just the bytes read - or NIL on
   EOF/would-block.  Same return contract as pty-read-blocking (fresh exact-size
   vector, or NIL), but BUFFER is reused across calls to eliminate the per-read
   4 KB allocation on the hot read path: only the (subseq buffer 0 count) result
   (count bytes) is freshly allocated.  Because that result is a copy, BUFFER may
   be safely overwritten by the next read even if the caller retains the result.

   Callers gate this with select-fds, so FD is ready when we read: cl-tty-kit's
   fd-read-octets then returns the available bytes (positive count) without
   waiting to fill BUFFER.  A 0 (EOF) or NIL (would-block) result maps to NIL -
   the 'no data / child gone' signal the reader treats as EOF, matching the
   previous %read-based convention."
  (let ((count (cl-tty-kit:fd-read-octets fd buffer)))
    (when (and count (plusp count))
      (subseq buffer 0 count))))

(defun pty-read-blocking (fd buffer-size)
  "Block until data arrives on FD, then return an octet vector of up to BUFFER-SIZE bytes.
   Returns NIL on EOF or error.

   Thin allocating wrapper over pty-read-blocking-into: allocates a fresh
   BUFFER-SIZE scratch buffer per call and reads into it, preserving the historic
   (fd size) signature for callers/tests that do not manage their own buffer."
  (pty-read-blocking-into
   fd (make-array buffer-size :element-type '(unsigned-byte 8))))

;;; -- Public: select-based I/O multiplexing --------------------------------

(defconstant +microseconds-per-second+ 1000000
  "Number of microseconds in one second; used in struct timeval decomposition.")

(defun %timeout-us-to-seconds (timeout-us)
  "Convert cl-tmux's microsecond timeout to process-kit's :TIMEOUT, in seconds.
   A negative TIMEOUT-US means \"block indefinitely\", which process-kit spells
   NIL. The quotient is left exact (a RATIO, not a float) because process-kit
   subtracts it from a rational deadline across EINTR retries."
  (when (>= timeout-us 0)
    (/ timeout-us +microseconds-per-second+)))

(defun %selectable-fds (fds)
  "The sub-list of FDS that select(2) can be asked about at all: non-negative
   integers.  A negative fd is cl-tmux's documented \"no PTY / dead pane\"
   sentinel (pane-fd -1), the same value PTY-WRITE guards above, and the event
   loop can still be holding one in its poll set for the iteration in which a
   pane is torn down.

   The hand-rolled %select this replaced tolerated that: it returned -1 and the
   positive-count guard turned the whole call into NIL.  PROCESS-KIT's
   %VALIDATE-FDS instead requires (INTEGER 0) and raises a BARE TYPE-ERROR -
   deliberately, so a descriptor number no caller could sensibly correct is not
   offered a STORE-VALUE restart - and a TYPE-ERROR is NOT a
   PROCESS-KIT:FD-WAIT-FAILED, so SELECT-FDS's handler-case below does not catch
   it.  Without this filter a dead pane in the reader loop becomes an unhandled
   error out of the event loop where it used to be a silent no-op.

   Filtered here rather than by widening the handler-case to TYPE-ERROR, for two
   reasons.  It restores the old contract exactly (a dead pane is simply not
   polled, and any live fds in the same call still are, instead of the whole poll
   collapsing to NIL).  And TYPE-ERROR is also how PROCESS-KIT reports a bad
   :TIMEOUT and how a genuine programming mistake - a stream or NIL reaching
   this list - would surface; swallowing those would turn a real bug into an
   event loop that quietly reports nothing ready forever.

   An fd above PROCESS-KIT:+MAXIMUM-FD+ (1022, two below FD_SETSIZE) is
   deliberately NOT filtered: PROCESS-KIT signals FD-SET-OVERFLOW for it, and a
   descriptor select(2) cannot watch is a caller bug - the old code met it with
   silence, and past FD_SETSIZE with memory corruption (see SELECT-FDS below) -
   not a sentinel to be swallowed."
  (remove-if-not (lambda (fd) (typep fd '(integer 0))) fds))

(defun select-fds (fds timeout-us)
  "Poll FDS for readability with a TIMEOUT-US microsecond timeout.
   timeout-us = 0 -> non-blocking; -1 -> block indefinitely.
   Returns the sub-list of fds that are ready to read, or NIL.
   Negative fds (the dead-pane sentinel) are dropped first; see %SELECTABLE-FDS.

   A thin wrapper over process-kit:wait-for-input rather than a direct call at
   each site: cl-tmux's microsecond/-1 convention is used by ~45 call sites in
   src/ and t/, and this one function is what the cl-tmux/ports layer and the
   test suite name. Converting here keeps that surface unchanged.

   Two behaviors improve on the hand-rolled select(2) this replaces.

   EINTR is now retried against a deadline fixed up front, instead of surfacing
   as a spurious \"nothing is ready\". The old code inspected the read-set only
   on a positive count, so a SIGWINCH or SIGCHLD landing mid-wait made this
   return NIL early - in the event loop that meant a resize or a child exit
   could cut a poll short and, with a -1 (infinite) timeout, restart the whole
   wait. process-kit resumes the remaining time instead.

   An fd above PROCESS-KIT:+MAXIMUM-FD+ now signals PROCESS-KIT:FD-SET-OVERFLOW.
   That ceiling is 1022, TWO below FD_SETSIZE, not 1023: select(2)'s first
   argument is one PAST the highest descriptor watched and must stay under
   FD_SETSIZE, so watching fd 1023 would mean passing 1024, which
   SB-UNIX:UNIX-FAST-SELECT refuses. Naming the bound as one documented condition
   is why fd 1023 is refused here rather than deeper down, where it used to
   surface as an untyped SIMPLE-ERROR.

   Not caught, deliberately. Past FD_SETSIZE the old fd-set! computed
   (floor fd 32) and wrote that word unconditionally, i.e. it scribbled past the
   end of a 128-byte fd_set; that is memory corruption, and any descriptor this
   library cannot watch is a caller bug rather than the closed-descriptor race
   below.

   PROCESS-KIT:FD-WAIT-FAILED (EBADF on a closed descriptor, say) IS mapped back
   to NIL, preserving the old contract: %select returned -1 and the positive-count
   guard yielded NIL. The event loop polls a set that a concurrently-detaching
   client can close underneath it, and turning that race into a signal would take
   the server down where it previously just iterated again."
  (let ((fds (%selectable-fds fds)))
    (when fds
      (handler-case
          (process-kit:wait-for-input fds :timeout (%timeout-us-to-seconds timeout-us))
        (process-kit:fd-wait-failed () nil)))))

;;; -- Port registration -----------------------------------------------------

(defun install-pty-port ()
  "Register this module as the active cl-tmux/ports PTY adapter."
  (setf cl-tmux/ports:*spawn-pty* #'forkpty-with-shell
        cl-tmux/ports:*write-pty* #'pty-write
        cl-tmux/ports:*resize-pty* #'set-pty-size
        cl-tmux/ports:*close-pty* #'pty-close))

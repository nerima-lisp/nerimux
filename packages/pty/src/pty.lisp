(in-package #:nerimux/pty)

;;;; PTY management, terminal raw mode, and multiplexed I/O.
;;;;
;;;; Implemented in pure Common Lisp using:
;;;;   • SB-EXT        — process spawning with a PTY stream
;;;;   • cl-tty-kit    — PTY creation, raw mode, fd read/write, window size
;;;;   • cl-process-kit — select(2) over raw fds
;;;;   • sb-posix      — signal delivery and fallback fd close
;;;;
;;;; Platform constants live in pty-ffi.lisp.
;;; ── Public: PTY creation ───────────────────────────────────────────────────
(defun set-pty-size (master-fd rows cols)
  "Notify the kernel PTY driver of a new ROWS×COLS window size.

   ARGUMENT ORDER: this function keeps nerimux's (MASTER-FD ROWS COLS) contract —
   it is installed as nerimux/ports:*resize-pty* and called from the domain — but
   cl-tty-kit:set-terminal-size takes (COLUMNS ROWS &optional FD). The call below
   therefore both TRANSPOSES rows/cols and moves the fd to the end. Getting this
   wrong silently swaps every pane's width and height, so it is covered by two
   round-trip tests on a non-square size, both of which set the size and read it
   back with cl-tty-kit:terminal-size:
     * SET-PTY-SIZE-ROUND-TRIPS-NON-SQUARE-SIZE-ON-REAL-PTY
       (tests/unit/infrastructure/pty/pty-tests.lisp), and
     * SET-PTY-SIZE-APPLIES-NON-SQUARE-SIZE-WITHOUT-TRANSPOSITION
       (tests/integration/pty-tests.lisp).
   Both need a real PTY and skip without one, so neither is a CI guard on a host
   with no /dev/ptmx; that is why the duplication is deliberate rather than
   redundant — the unit suite is the one that runs in `nix develop`.
   The same transposition, in the read direction, is done by TERMINAL-SIZE below.

   This is also a BUG FIX. The previous implementation called variadic ioctl(2)
   through a FIXED cffi prototype. On the arm64 ABI a variadic argument is passed
   on the stack while a fixed prototype passes it in a register, so the kernel
   read a garbage pointer and the call failed with EFAULT: verified on this
   machine, where the fixed-prototype TIOCSWINSZ returned -1 and left the pty at
   0x0, while SBCL's own sb-unix:unix-ioctl (what cl-tty-kit uses) set 40x123
   correctly on the same fd. set-pty-size was therefore a silent no-op on Apple
   Silicon — every child process saw a stale or zero window size and SIGWINCH was
   never delivered.

   cl-tty-kit signals TERMINAL-SIZE-SET-FAILED on failure, whereas the old ioctl
   returned -1 that no caller inspected. FORKPTY-WITH-SHELL calls this inside an
   unwind-protect that tears the pty down, and the resize command path wraps it,
   so a genuine failure now surfaces instead of leaving a wrongly-sized pane.

   ROWS and COLS must both be POSITIVE. cl-tty-kit's %ASSERT-TERMINAL-DIMENSION
   rejects 0 (and anything negative) before attempting the ioctl, where the old
   cffi path passed a 0x0 winsize through and ignored the -1 return. A degenerate
   layout can produce a zero content height, so NERIMUX/MODEL:PANE-REPOSITION —
   the only caller that computes its dimensions rather than receiving them —
   guards (PLUSP WIDTH) and (PLUSP CONTENT-HEIGHT) alongside its fd guard."
  (cl-tty-kit:set-terminal-size cols rows master-fd))

;;; ── Private: spawned PTY helpers ───────────────────────────────────────────
(defvar *pty-processes*
  (make-hash-table :synchronized t)
  "MASTER-FD -> cl-tty-kit PTY struct for PTYs spawned by forkpty-with-shell.
   :synchronized so the reader thread (pty-child-exit-status reads) and teardown
   (pty-close remhash) can touch it concurrently without a coarse external lock.
   The cl-tty-kit PTY struct owns the SBCL process object and its master stream;
   retaining it here keeps that stream (and therefore the master fd nerimux holds)
   reachable for the pane's lifetime, so SBCL's GC cannot close the fd out from
   under us.  pty-close / pty-child-exit-status reap through this table.")

(defun %string-non-empty-p (value)
  "Return T when VALUE is a non-empty string."
  (and (stringp value) (plusp (length value))))

(defun %spawn-directory (start-dir)
  "Return a truename pathname for START-DIR, or NIL when it is absent/invalid.
   The old child path ignored chdir failures; keeping NIL preserves that behavior
   by letting the child inherit the current directory."
  (when (%string-non-empty-p start-dir)
    (handler-case (truename start-dir)
      (file-error ()
        nil))))

(defun %default-shell ()
  "Shell to spawn for a pane's child process: $SHELL, or \"/bin/sh\" when unset
   (§1.4 — the shell is no longer configurable, so this is the whole rule)."
  (let ((shell (sb-ext:posix-getenv "SHELL")))
    (if (%string-non-empty-p shell)
        shell
        "/bin/sh")))

(defun %target-program-and-args (default-command)
  "Return (values PROGRAM ARGS SEARCH-P) for SB-EXT:RUN-PROGRAM.
   When DEFAULT-COMMAND is a non-empty string, run it via /bin/sh -c.
   Otherwise run %DEFAULT-SHELL directly, searching PATH for it (SEARCH-P)
   unless it is already given as an absolute path."
  (if (%string-non-empty-p default-command)
      (values "/bin/sh" (list "-c" default-command) nil)
      (let ((shell (%default-shell)))
        (values shell nil (not (char= (char shell 0) #\/))))))

(defun %remember-pty-process (master-fd pty)
  "Record the cl-tty-kit PTY struct so pty-close can reap it and so the struct
   (and the master stream/fd it owns) stays reachable for the pane's lifetime."
  (setf (gethash master-fd *pty-processes*) pty))

(defun %take-pty-process (master-fd)
  "Remove and return the cl-tty-kit PTY struct associated with MASTER-FD, if any."
  (let ((pty (gethash master-fd *pty-processes*)))
    (remhash master-fd *pty-processes*)
    pty))

(defparameter +pty-child-wait-timeout+
  (cl-date-kit:duration-of-seconds 5)
  "Wall-clock timeout, as a CL-DATE-KIT:DURATION, for PTY-CHILD-EXIT-STATUS's
   wait on a child that has already closed its PTY slave.  The child should
   already be exiting by then; this bounds the rare case where it lingers (e.g.
   a daemonizing grandchild still holding the PTY open) so the reader thread
   that calls this at EOF cannot block forever.")

(defconstant +pty-write-timeout-seconds+
  2
  "Wall-clock timeout, in bare seconds, for PTY-WRITE's write to a PTY master
   fd.  Bare seconds rather than a CL-DATE-KIT:DURATION: this bounds an
   SB-EXT:WITH-TIMEOUT call, not a CL-CONCURRENT-KIT:WITH-TIMEOUT one (see
   +PTY-CHILD-WAIT-TIMEOUT+ above for that distinct convention), and mirrors
   +SEND-FRAME-TIMEOUT-SECONDS+ (infrastructure/net/transport.lisp), which
   takes the same bare form for the same reason.

   PTY-WRITE has TWO callers, on two different threads, and both matter:

     * %HANDLE-CLIENT-INPUT-KEY-PAYLOAD
       (bootstrap/server-multi-dispatch-command-input.lisp), on the single
       serve-loop thread -- an unbounded write against a full PTY input
       buffer would hang every attached client with no recovery.  This is the
       hot path: it forwards one keystroke, 1-4 UTF-8 bytes.
     * %DRAIN-RESPONSE-QUEUE (domain/model/pane-core.lisp), reached through
       PANE-FEED on the PER-PANE READER THREAD, writing device-report replies
       (DA1/DA2/CPR/DSR/DECRQM/XTGETTCAP/DECRQSS/OSC-colour) back to the
       child.  PTY-WRITE reaches it as NERIMUX/PORTS:*WRITE-PTY*, which is
       why a grep for direct callers misses it.

   The second one is the dangerous one and an earlier version of this
   docstring denied it existed.  An unhandled condition on a non-main thread
   does not kill just that thread: under --disable-debugger SBCL quits the
   whole process.  READER-READING-STATE (bootstrap/runtime-reader.lisp)
   therefore contains PEER-IO-FAILURE around its PANE-FEED call; do not
   remove that guard while this timeout exists.

   2 seconds is long enough for a transient backlog (a child busy processing
   a burst of input) to drain, and short enough that a genuinely stuck pane
   stalls its caller for a bounded, barely perceptible instant instead of
   forever.

   Measured cost, so the tradeoff is on the record: SB-EXT:WITH-TIMEOUT
   registers and deregisters a timer against SBCL's global timer queue on
   every call, costing ~228 bytes consed per call against 0 for the bare
   write.  On the keystroke path that is per-keystroke.  Accepted here
   because the alternative it replaces is an unbounded hang of every client;
   arming the timer only after a non-blocking first write reports EWOULDBLOCK
   would remove the cost from the common case, and is the change to make if
   this ever shows up in a profile.")

(defun pty-child-exit-status (master-fd &optional (timeout +pty-child-wait-timeout+))
  "Exit information for MASTER-FD's child process, called at PTY EOF (the child
   has closed the slave, so the wait does not normally block for a live shell;
   bounded by TIMEOUT, a CL-DATE-KIT:DURATION, default
   +PTY-CHILD-WAIT-TIMEOUT+ — override only for tests that need a live child to
   time out quickly). NIL leaves the wait unbounded.
   Returns (values CODE KIND) where KIND is :exited (CODE = exit code) or
   :signaled (CODE = NIL on SBCL, whose process API does not expose the signal
   number), or NIL when the child is unknown (foreign
   fd, synthetic test pane), the wait times out, or the wait fails."
  (let* ((pty (gethash master-fd *pty-processes*))
         (process (and pty (cl-tty-kit:pty-process pty))))
    (when process
      (handler-case
          (progn
            ;; Bare deadline form, not (timeout): cl-concurrent-kit's WITH-TIMEOUT
            ;; is shaped like SB-EXT:WITH-TIMEOUT, not bordeaux-threads'.
            (cl-concurrent-kit:with-timeout timeout
              (sb-ext:process-wait process))
            (let ((code (sb-ext:process-exit-code process)))
              (when code
                (if (eq (sb-ext:process-status process) :signaled)
                    (values nil :signaled)
                    (values code :exited)))))
        (cl-concurrent-kit:operation-timed-out () nil)
        (error () nil)))))

(defun forkpty-with-shell (rows cols &key start-dir default-command environment)
  "Spawn a child shell process on a fresh PTY of size ROWS×COLS.
   START-DIR: when valid, run the child from this directory.
   DEFAULT-COMMAND: when non-NIL, run via sh -c instead of the shell directly.
   ENVIRONMENT: flat list of NAME=VALUE strings passed to RUN-PROGRAM.
   Returns (values master-fd child-pid slave-path).  SBCL exposes the master
   stream and pid but not a portable slave-path, so SLAVE-PATH is currently the
   empty string."
  (declare (type fixnum rows cols))
  ;; nerimux assembles the program/args/environment/directory; cl-tty-kit performs
  ;; the actual sb-ext:run-program :pty t spawn (the same mechanism nerimux used
  ;; directly before).  cl-tty-kit always searches PATH for a relative program,
  ;; which subsumes nerimux's SEARCH-P (absolute programs like /bin/sh are found
  ;; regardless), so SEARCH-P is no longer threaded through.
  (multiple-value-bind (program args search-p)
      (%target-program-and-args default-command)
    (declare (ignore search-p))
    (let ((pty (cl-tty-kit:make-pty :program program
                                    :args args
                                    :environment environment
                                    :directory (%spawn-directory start-dir)))
          (success nil))
      ;; make-pty has already spawned the child.  Everything below (fd/pid
      ;; extraction, ioctl resize, table registration) can signal; until
      ;; %remember-pty-process records the pty in *pty-processes*, nothing else
      ;; can reap the child or close the master fd.  Guard the post-spawn steps
      ;; so a non-local exit before successful registration tears the pty down
      ;; (closing its process + master stream/fd), avoiding a child/fd leak.
      (unwind-protect
           (let ((master (cl-tty-kit:pty-fd pty))
                 (pid (cl-tty-kit:pty-pid pty)))
             (set-pty-size master rows cols)
             ;; Retain the cl-tty-kit PTY struct keyed by MASTER so it (and the fd
             ;; it owns) survives GC until pty-close reaps it.
             (%remember-pty-process master pty)
             (setf success t)
             ;; SBCL exposes the master stream and pid but not a portable slave
             ;; path, so SLAVE-PATH stays the empty string, preserving the pane
             ;; tty field's existing (empty) value that callers store.
             (values master pid ""))
        (unless success
          (handler-case
              (cl-tty-kit:close-pty pty)
            (cl-tty-kit:pty-operation-failed () nil)))))))

;;; ── Public: PTY I/O ────────────────────────────────────────────────────────
;;;
;;; Byte-transparent master-fd read/write is delegated to cl-tty-kit's
;;; fd-centric layer (fd-read-octets / fd-write-octets), which wraps the same
;;; unix-read/unix-write calls nerimux formerly issued via CFFI.  nerimux keeps
;;; its own type-guarding and empty-noop conventions here so callers and tests
;;; observe unchanged behavior.
(defun pty-write (fd data)
  "Write DATA (octet vector or UTF-8 string) to the PTY master fd, within
   +PTY-WRITE-TIMEOUT-SECONDS+.  Signals SB-EXT:TIMEOUT when the write does
   not complete in time (a full PTY input buffer against a stuck child), the
   way SEND-FRAME (infrastructure/net/transport.lisp) signals it for a slow
   peer -- see +PTY-WRITE-TIMEOUT-SECONDS+'s docstring for why this caller in
   particular must not block unbounded."
  (etypecase data
    (string
     (pty-write fd (cl-codec-kit:string-to-octets data :encoding :utf-8)))
    ((simple-array (unsigned-byte 8) (*))
     ;; Two noop guards preserving the prior raw-write(2) behavior:
     ;;   * empty vector — no write is issued (tests assert this).
     ;;   * negative fd — the "no PTY / dead pane" sentinel (pane-fd -1).  The
     ;;     former CFFI write(2) ignored its return value, so a write to fd -1
     ;;     silently failed; cl-tty-kit's fd-write-octets instead asserts a
     ;;     non-negative fd and signals, so we skip it here.  Real PTY master fds
     ;;     are always positive, and the domain already gates real writes on
     ;;     (> (pane-fd pane) 0).
     (when (and (>= fd 0) (plusp (length data)))
       (sb-ext:with-timeout +pty-write-timeout-seconds+
         (cl-tty-kit:fd-write-octets fd data))))))

(defun pty-read-blocking-into (fd buffer)
  "Block until data arrives on FD, read into the caller-supplied octet BUFFER, and
   return a fresh exact-size octet vector holding just the bytes read — or NIL on
   EOF/would-block.  BUFFER is reused across calls to eliminate the per-read
   4 KB allocation on the hot read path: only the (subseq buffer 0 count) result
   (count bytes) is freshly allocated.  Because that result is a copy, BUFFER may
   be safely overwritten by the next read even if the caller retains the result.

   Callers gate this with select-fds, so FD is ready when we read: cl-tty-kit's
   fd-read-octets then returns the available bytes (positive count) without
   waiting to fill BUFFER.  A 0 (EOF) or NIL (would-block) result maps to NIL —
   the 'no data / child gone' signal the reader treats as EOF, matching the
   previous %read-based convention."
  (let ((count (cl-tty-kit:fd-read-octets fd buffer)))
    (when (and count (plusp count))
      (subseq buffer 0 count))))

(defun pty-close (master-fd child-pid)
  "Send SIGHUP to the child process and close the PTY master.

   A non-positive CHILD-PID is ignored: kill(-1)/kill(0) broadcast the signal to
   the whole process group (including this process), which must never happen.
   Likewise a negative MASTER-FD is not closed."
  ;; nerimux-specific teardown: SIGHUP (NOT cl-tty-kit's SIGTERM->SIGKILL
  ;; escalation) then close the master.  Drop the retained cl-tty-kit PTY
  ;; struct from *pty-processes* so it is no longer reachable; closing its
  ;; SBCL process object closes the master stream (and fd), as before.
  ;; sb-posix:kill, NOT process-kit's signal API: that one is shaped around a
  ;; process handle it spawned and checks process-group ownership, whereas
  ;; nerimux holds a bare pid from a cl-tty-kit PTY. sb-posix ships with SBCL
  ;; and is not an external dependency.
  (when (plusp child-pid)
    (handler-case
        (sb-posix:kill child-pid sb-posix:sighup)
      (sb-posix:syscall-error () nil)))
  (when (>= master-fd 0)
    (let ((pty (%take-pty-process master-fd)))
      (if pty
          (handler-case
              (sb-ext:process-close (cl-tty-kit:pty-process pty))
            (stream-error () nil)
            (file-error () nil))
          (handler-case
              (sb-posix:close master-fd)
            (sb-posix:syscall-error () nil))))))

;;; ── Public: select-based I/O multiplexing ─────────────────────────────────
(defconstant +microseconds-per-second+
  1000000
  "Number of microseconds in one second; used in struct timeval decomposition.")

(defun %timeout-us-to-seconds (timeout-us)
  "Convert nerimux's microsecond timeout to process-kit's :TIMEOUT, in seconds.
   A negative TIMEOUT-US means \"block indefinitely\", which process-kit spells
   NIL. The quotient is left exact (a RATIO, not a float) because process-kit
   subtracts it from a rational deadline across EINTR retries."
  (when (>= timeout-us 0)
    (/ timeout-us +microseconds-per-second+)))

(defun %selectable-fds (fds)
  "The sub-list of FDS that select(2) can be asked about at all: non-negative
   integers.  A negative fd is nerimux's documented \"no PTY / dead pane\"
   sentinel (pane-fd -1), the same value PTY-WRITE guards above, and the event
   loop can still be holding one in its poll set for the iteration in which a
   pane is torn down.

   The hand-rolled %select this replaced tolerated that: it returned -1 and the
   positive-count guard turned the whole call into NIL.  PROCESS-KIT's
   %VALIDATE-FDS instead requires (INTEGER 0) and raises a BARE TYPE-ERROR —
   deliberately, so a descriptor number no caller could sensibly correct is not
   offered a STORE-VALUE restart — and a TYPE-ERROR is NOT a
   PROCESS-KIT:FD-WAIT-FAILED, so SELECT-FDS's handler-case below does not catch
   it.  Without this filter a dead pane in the reader loop becomes an unhandled
   error out of the event loop where it used to be a silent no-op.

   Filtered here rather than by widening the handler-case to TYPE-ERROR, for two
   reasons.  It restores the old contract exactly (a dead pane is simply not
   polled, and any live fds in the same call still are, instead of the whole poll
   collapsing to NIL).  And TYPE-ERROR is also how PROCESS-KIT reports a bad
   :TIMEOUT and how a genuine programming mistake — a stream or NIL reaching this
   list — would surface; swallowing those would turn a real bug into an event
   loop that quietly reports nothing ready forever.

   An fd above PROCESS-KIT:+MAXIMUM-FD+ (1022, two below FD_SETSIZE) is
   deliberately NOT filtered: PROCESS-KIT signals FD-SET-OVERFLOW for it, and a
   descriptor select(2) cannot watch is a caller bug — the old code met it with
   silence, and past FD_SETSIZE with memory corruption (see SELECT-FDS below) —
   not a sentinel to be swallowed."
  (remove-if-not
   (lambda (fd)
     (typep fd '(integer 0)))
   fds))

(defun select-fds (fds timeout-us)
  "Poll FDS for readability with a TIMEOUT-US microsecond timeout.
   timeout-us = 0 → non-blocking; -1 → block indefinitely.
   Returns the sub-list of fds that are ready to read, or NIL.
   Negative fds (the dead-pane sentinel) are dropped first; see %SELECTABLE-FDS.

   A thin wrapper over process-kit:wait-for-input rather than a direct call at
   each site: nerimux's microsecond/-1 convention is used by ~45 call sites in
   src/ and tests/, and this one function is what the nerimux/ports layer and the
   test suite name. Converting here keeps that surface unchanged.

   Two behaviors improve on the hand-rolled select(2) this replaces.

   EINTR is now retried against a deadline fixed up front, instead of surfacing
   as a spurious \"nothing is ready\". The old code inspected the read-set only
   on a positive count, so a SIGWINCH or SIGCHLD landing mid-wait made this
   return NIL early — in the event loop that meant a resize or a child exit
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
      (handler-case (process-kit:wait-for-input fds
                                                :timeout
                                                (%timeout-us-to-seconds
                                                 timeout-us))
        (process-kit:fd-wait-failed ()
          nil)))))

;;; ── Public: terminal geometry ──────────────────────────────────────────────
(defconstant +max-sane-rows+
  1000)

(defconstant +max-sane-cols+
  1000)

(defconstant +default-term-rows+
  24)

(defconstant +default-term-cols+
  80)

(defun terminal-size ()
  "Return terminal dimensions as (values rows cols), with safe fallbacks."
  (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size +stdout-fd+)
    (if (and (integerp rows)
             (integerp cols)
             (<= 1 rows +max-sane-rows+)
             (<= 1 cols +max-sane-cols+))
        (values rows cols)
        (values +default-term-rows+ +default-term-cols+))))

;;; ── Port adapter ─────────────────────────────────────────────────────────────
;;;
;;; install-pty-port wires this module's PTY functions into the
;;; nerimux/ports abstraction layer so that domain code (nerimux/model) calls
;;; through the port rather than referencing nerimux/pty symbols directly.
;;; Must be called before any pane is created (server startup or test setup).
(defun install-pty-port ()
  "Register this module as the active nerimux/ports PTY adapter."
  (setf nerimux/ports:*spawn-pty* #'forkpty-with-shell
        nerimux/ports:*write-pty* #'pty-write
        nerimux/ports:*resize-pty* #'set-pty-size
        nerimux/ports:*close-pty* #'pty-close))

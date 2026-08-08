(in-package #:cl-tmux/pty)

;;;; PTY lifecycle and terminal geometry.
;;;;
;;;; Implemented in pure Common Lisp using:
;;;;   • cl-tty-kit         — PTY creation, process ownership, raw mode, window size
;;;;   • cl-concurrent-kit  — bounded child wait
;;;;   • sb-posix           — signal delivery and fallback fd close
;;;;
;;;; Platform constants live in pty-ffi.lisp.

;;; ── Public: PTY creation ───────────────────────────────────────────────────

(defun set-pty-size (master-fd rows cols)
  "Notify the kernel PTY driver of a new ROWS×COLS window size.

   ARGUMENT ORDER: this function keeps cl-tmux's (MASTER-FD ROWS COLS) contract —
   it is installed as cl-tmux/ports:*resize-pty* and called from the domain — but
   cl-tty-kit:set-terminal-size takes (COLUMNS ROWS &optional FD). The call below
   therefore both TRANSPOSES rows/cols and moves the fd to the end. Getting this
   wrong silently swaps every pane's width and height, so it is covered by two
   round-trip tests on a non-square size, both of which set the size and read it
   back with cl-tty-kit:terminal-size:
     * SET-PTY-SIZE-ROUND-TRIPS-NON-SQUARE-SIZE-ON-REAL-PTY
       (t/unit/infrastructure/pty/pty-tests.lisp), and
     * SET-PTY-SIZE-APPLIES-NON-SQUARE-SIZE-WITHOUT-TRANSPOSITION
       (t/integration/pty-tests.lisp).
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
   layout can produce a zero content height, so CL-TMUX/MODEL:PANE-REPOSITION —
   the only caller that computes its dimensions rather than receiving them —
   guards (PLUSP WIDTH) and (PLUSP CONTENT-HEIGHT) alongside its fd guard."
  (cl-tty-kit:set-terminal-size cols rows master-fd))

;;; ── Private: spawned PTY helpers ───────────────────────────────────────────

(defvar *pty-processes* (make-hash-table :test #'eql :synchronized t)
  "MASTER-FD -> cl-tty-kit PTY struct for PTYs spawned by forkpty-with-shell.
   :synchronized so the reader thread (pty-child-exit-status reads) and teardown
   (pty-close remhash) can touch it concurrently without a coarse external lock.
   The cl-tty-kit PTY struct owns the SBCL process object and its master stream;
   retaining it here keeps that stream (and therefore the master fd cl-tmux holds)
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
    (ignore-errors (truename start-dir))))

(defun %target-program-and-args (default-command)
  "Return (values PROGRAM ARGS SEARCH-P) for SB-EXT:RUN-PROGRAM.
   When DEFAULT-COMMAND is a non-empty string, run it via /bin/sh -c.
   Otherwise run the configured default shell directly, searching PATH for it
   (SEARCH-P) unless it is already given as an absolute path."
  (if (%string-non-empty-p default-command)
      (values "/bin/sh" (list "-c" default-command) nil)
      (values cl-tmux/config:*default-shell* nil
              (not (and (stringp cl-tmux/config:*default-shell*)
                        (plusp (length cl-tmux/config:*default-shell*))
                        (char= (char cl-tmux/config:*default-shell* 0) #\/))))))

(defun %remember-pty-process (master-fd pty)
  "Record the cl-tty-kit PTY struct so pty-close can reap it and so the struct
   (and the master stream/fd it owns) stays reachable for the pane's lifetime."
  (setf (gethash master-fd *pty-processes*) pty))

(defun %take-pty-process (master-fd)
  "Remove and return the cl-tty-kit PTY struct associated with MASTER-FD, if any."
  (let ((pty (gethash master-fd *pty-processes*)))
    (remhash master-fd *pty-processes*)
    pty))

(defconstant +pty-child-wait-timeout+ 5
  "Wall-clock timeout, in seconds, for PTY-CHILD-EXIT-STATUS's wait on a child
   that has already closed its PTY slave.  The child should already be
   exiting by then; this bounds the rare case where it lingers (e.g. a
   daemonizing grandchild still holding the PTY open) so the reader thread
   that calls this at EOF cannot block forever.")

(defun pty-child-exit-status
    (master-fd &optional (timeout +pty-child-wait-timeout+))
  "Exit information for MASTER-FD child process, called at PTY EOF (the child
has closed the slave, so the wait does not normally block for a live shell;
bounded by TIMEOUT seconds regardless, default +PTY-CHILD-WAIT-TIMEOUT+.
Returns (values CODE KIND) where KIND is :exited (CODE = exit code) or
:signaled (CODE = signal number), or NIL when the child is unknown (foreign
fd, synthetic test pane), the wait times out, or the wait fails."
  (let* ((pty (gethash master-fd *pty-processes*))
         (process (and pty (cl-tty-kit:pty-process pty))))
    (when process
      (handler-case
          (progn
            (cl-concurrent-kit:with-timeout
                (cl-date-kit:duration-of-nanos
                 (round (* timeout 1000000000)))
              (sb-ext:process-wait process))
            (let ((code (sb-ext:process-exit-code process)))
              (when code
                (if (eq (sb-ext:process-status process) :signaled)
                    (values code :signaled)
                    (values code :exited)))))
        (cl-concurrent-kit:operation-timed-out () nil)
        (error (condition)
          (if (typep condition (quote type-error))
              (error condition)
              nil))))))

(defun forkpty-with-shell (rows cols &key start-dir default-command environment)
  "Spawn a child shell process on a fresh PTY of size ROWS×COLS.
   START-DIR: when valid, run the child from this directory.
   DEFAULT-COMMAND: when non-NIL, run via sh -c instead of the shell directly.
   ENVIRONMENT: flat list of NAME=VALUE strings passed to RUN-PROGRAM.
   Returns (values master-fd child-pid slave-path).  SBCL exposes the master
   stream and pid but not a portable slave-path, so SLAVE-PATH is currently the
   empty string."
  (declare (type fixnum rows cols))
  ;; cl-tmux assembles the program/args/environment/directory; cl-tty-kit performs
  ;; the actual sb-ext:run-program :pty t spawn (the same mechanism cl-tmux used
  ;; directly before).  cl-tty-kit always searches PATH for a relative program,
  ;; which subsumes cl-tmux's SEARCH-P (absolute programs like /bin/sh are found
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
          (ignore-errors (cl-tty-kit:close-pty pty)))))))

(defun pty-close (master-fd child-pid)
  "Send SIGHUP to the child process and close the PTY master.

   A non-positive CHILD-PID is ignored: kill(-1)/kill(0) broadcast the signal to
   the whole process group (including this process), which must never happen.
   Likewise a negative MASTER-FD is not closed."
  ;; A child can exit between the fork and this cleanup.  Keep its failed
  ;; SIGHUP from preventing close-pty from releasing the retained stream.
  (when (> child-pid 0)
    (ignore-errors
      (sb-posix:kill child-pid sb-posix:sighup)))
  (when (>= master-fd 0)
    (let ((pty (%take-pty-process master-fd)))
      (if pty
          (ignore-errors
            (cl-tty-kit:close-pty pty))
          (ignore-errors
            (sb-posix:close master-fd))))))

;;; ── Public: terminal geometry ──────────────────────────────────────────────

(defconstant +max-sane-rows+ 1000
  "Upper bound on terminal rows accepted from ioctl; values above this are clamped.")
(defconstant +max-sane-cols+ 1000
  "Upper bound on terminal columns accepted from ioctl; values above this are clamped.")

(defconstant +default-term-rows+ 24
  "Fallback terminal height in rows, used when ioctl fails or reports a
   nonsensical size (e.g., a transient 0x0 read). Mirrors the *term-rows*
   defvar default in runtime.lisp.")
(defconstant +default-term-cols+ 80
  "Fallback terminal width in columns, used when ioctl fails or reports a
   nonsensical size (e.g., a transient 0x0 read). Mirrors the *term-cols*
   defvar default in runtime.lisp.")

(defun terminal-size ()
  "Return (values rows cols) of the terminal attached to stdout.
   Falls back to +default-term-rows+ x +default-term-cols+ if ioctl fails or
   reports an out-of-range size (a transient 0x0 or garbage read must not
   drive a resize).

   The underlying TIOCGWINSZ query is delegated to cl-tty-kit:terminal-size,
   which returns (values COLUMNS ROWS) — columns first.  We SWAP that to
   cl-tmux's (values ROWS COLS) contract; a transpose here would corrupt every
   pane's geometry.  cl-tty-kit returns (values NIL NIL) when the size is
   unavailable, which fails the integerp/range check below and falls back."
  (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size +stdout-fd+)
    (if (and (integerp rows) (integerp cols)
             (<= 1 rows +max-sane-rows+)
             (<= 1 cols +max-sane-cols+))
        (values rows cols)
        (values +default-term-rows+ +default-term-cols+))))

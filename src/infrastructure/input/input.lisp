(in-package #:cl-tmux/input)

;;;; Keyboard input: raw-mode wrapper and non-blocking stdin reads.
;;;;
;;;; We read from fd 0 (stdin) at the descriptor level rather than through a
;;;; Lisp stream because Lisp streams may buffer; we need single bytes. The
;;;; readiness poll goes through cl-tmux/pty:select-fds (cl-process-kit) and the
;;;; read itself through cl-tty-kit:fd-read-octets, the same function
;;;; pty-read-blocking-into already uses for the PTY master side.

;;; ── Raw-mode convenience macro ─────────────────────────────────────────────

(defmacro with-raw-mode (&body body)
  "Execute BODY with stdin in raw mode, restoring the terminal on exit.
   ENABLE-RAW-MODE! runs OUTSIDE the unwind-protect deliberately: cl-tty-kit's
   enable-raw-mode only records fd 0 as raw AFTER its TCSETATTR syscall
   succeeds, so if it signals an error the terminal was never actually put
   into raw mode and there is nothing to restore. A handler-bind safety net
   used to call disable-raw-mode! unconditionally here, but handler-bind
   runs its handler BEFORE unwinding the stack — if enable-raw-mode! itself
   was the one signalling (still holding cl-tty-kit's internal raw-mode
   lock), that handler's disable-raw-mode! call recursed on the same lock
   from the same thread, crashing with a masking \"recursive lock attempt\"
   error instead of the real one."
  `(progn
     (enable-raw-mode! 0)        ; fd 0 = stdin
     (unwind-protect
          (progn ,@body)
       (disable-raw-mode! 0)
       ;; Move cursor to a clean line after restoring
       (format t "~%")
       (force-output))))

;;; ── Non-blocking byte read ─────────────────────────────────────────────────

(defun read-byte-nonblock (&optional (timeout-us +poll-timeout-us+))
  "Return a byte (0–255) from stdin within TIMEOUT-US microseconds, or NIL.
   NIL means the timeout elapsed with no data — it does NOT mean EOF.
   EOF on stdin is indistinguishable from a zero-byte read at this layer;
   both return NIL.  TIMEOUT-US = 0 is a purely non-blocking poll.

   cl-tty-kit:fd-read-octets already collapses the cases the raw read(2) call
   this replaces had to distinguish by hand: it returns a positive count for
   data, 0 at EOF, and NIL when the read would have blocked (EAGAIN/EWOULDBLOCK)
   or a signal interrupted it (EINTR).  Only a count of exactly 1 yields a byte,
   so EOF and would-block both fall through to NIL — the documented contract
   above, unchanged.

   A hard OS error is the one case whose handling had to change rather than be
   copied: the old code ignored read(2)'s -1 return and produced NIL, whereas
   fd-read-octets signals PTY-OPERATION-FAILED.  It is mapped back to NIL here
   so an unreadable stdin cannot take down the interactive key loop, matching
   both the previous behavior and this function's stated \"or NIL\" contract."
  (declare (type fixnum timeout-us))
  (let ((ready (cl-tmux/pty:select-fds (list 0) timeout-us)))
    (when ready
      ;; Read exactly one byte from fd 0 directly (bypasses Lisp buffering).
      (let ((buffer (make-array 1 :element-type '(unsigned-byte 8))))
        (let ((count (handler-case (cl-tty-kit:fd-read-octets 0 buffer 1)
                       (cl-tty-kit:pty-operation-failed () nil))))
          (when (eql count 1)
            (aref buffer 0)))))))

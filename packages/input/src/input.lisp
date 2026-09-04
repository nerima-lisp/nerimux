(in-package #:nerimux/input)

(defmacro with-raw-mode (&body body)
  "Execute BODY with stdin in raw mode, restoring the terminal on exit.
   ENABLE-RAW-MODE! runs OUTSIDE the unwind-protect deliberately: cl-tty-kit's
   enable-raw-mode only records fd 0 as raw AFTER its TCSETATTR syscall
   succeeds, so if it signals an error the terminal was never actually put
   into raw mode and there is nothing to restore. Keeping the call outside
   the UNWIND-PROTECT also avoids re-entering cl-tty-kit's raw-mode lock
   while a failing enable operation still holds it."
  `(progn
     (enable-raw-mode! 0)        ; fd 0 = stdin
     (unwind-protect
          (progn ,@body)
       (disable-raw-mode! 0)
       (format t "~%")
       (force-output))))

(defun read-byte-nonblock (&optional (timeout-us +poll-timeout-us+))
  "Return a byte (0–255) from stdin within TIMEOUT-US microseconds, or NIL.
   NIL means the timeout elapsed with no data — it does NOT mean EOF.
   EOF on stdin is indistinguishable from a zero-byte read at this layer;
   both return NIL.  TIMEOUT-US = 0 is a purely non-blocking poll.

   cl-tty-kit:fd-read-octets returns a positive count for data, 0 at EOF, and
   NIL when the read would block or is interrupted. Only a count of exactly 1
   yields a byte, so EOF and would-block both return NIL. PTY-OPERATION-FAILED
   is also mapped to NIL so an unreadable stdin cannot terminate the key loop."
  (declare (type fixnum timeout-us))
  (let ((ready (nerimux/pty:select-fds (list 0) timeout-us)))
    (when ready
      (let ((buffer (make-array 1 :element-type '(unsigned-byte 8))))
        (let ((count (handler-case (cl-tty-kit:fd-read-octets 0 buffer 1)
                       (cl-tty-kit:pty-operation-failed () nil))))
          (when (eql count 1)
            (aref buffer 0)))))))

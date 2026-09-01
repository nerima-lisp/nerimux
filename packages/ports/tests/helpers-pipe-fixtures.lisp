(in-package #:nerimux/test/ports)

;;;; POSIX pipe fixtures.
(defun write-octets-to-fd (fd octets)
  "Write OCTETS, a sequence of (unsigned-byte 8), to file descriptor FD.
   Returns the number of bytes written.  Goes through cl-tty-kit:fd-write-octets,
   the same call production pty-write uses, now that nerimux has no cffi."
  (cl-tty-kit:fd-write-octets fd
                              (coerce octets
                                      '(simple-array (unsigned-byte 8) (*)))))

(defun write-byte-to-fd (fd byte-value)
  "Write a single BYTE-VALUE (0–255) to file descriptor FD.
   Returns the number of bytes written (1 on success).
   Shared by input-tests.lisp and pty-tests.lisp to eliminate repeated
   single-byte write patterns."
  (write-octets-to-fd fd (vector byte-value)))

(defun read-octets-from-fd (fd count)
  "Read up to COUNT bytes from FD and return them as a fresh octet vector,
   or NIL on EOF/would-block.  The counterpart of WRITE-OCTETS-TO-FD, replacing
   the cffi:with-foreign-object / foreign-funcall \"read\" / mem-aref pattern
   that was repeated across six test files.  Callers gate this with select-fds,
   so the fd is ready and one read returns the bytes already buffered."
  (let* ((buffer (make-array count :element-type '(unsigned-byte 8)))
         (n (cl-tty-kit:fd-read-octets fd buffer count)))
    (when (and n (plusp n))
      (subseq buffer 0 n))))

(defmacro with-pipe-fds ((read-fd write-fd) &body body)
  "Open a POSIX pipe; bind READ-FD and WRITE-FD; close both on exit.
   BODY may begin with (declare ...) forms; they are valid in locally's body.
   Shared by input-tests.lisp, pty-tests.lisp, and pty-rawmode-tests.lisp."
  (let ((pair-sym (gensym "PAIR")))
    `(let* ((,pair-sym (multiple-value-list (sb-posix:pipe)))
            (,read-fd (first ,pair-sym))
            (,write-fd (second ,pair-sym)))
       (unwind-protect 
           (locally
             ,@body)
         (ignore-errors (sb-posix:close ,read-fd))
         (ignore-errors (sb-posix:close ,write-fd))))))

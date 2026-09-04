(in-package #:nerimux/pty)
(defun pty-write (fd data)
  (etypecase data
    (string (pty-write fd (cl-codec-kit:string-to-octets data :encoding :utf-8)))
    ((simple-array (unsigned-byte 8) (*))
     (when (and (>= fd 0) (plusp (length data)))
       (sb-ext:with-timeout +pty-write-timeout-seconds+
         (cl-tty-kit:fd-write-octets fd data))))))
(defun pty-read-blocking-into (fd buffer)
  (let ((count (cl-tty-kit:fd-read-octets fd buffer)))
    (when (and count (plusp count)) (subseq buffer 0 count))))

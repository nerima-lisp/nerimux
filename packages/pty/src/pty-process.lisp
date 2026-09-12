(in-package #:nerimux/pty)

(defvar *pty-processes*
  (make-hash-table :synchronized t)
  "MASTER-FD -> cl-tty-kit PTY struct for PTYs spawned by forkpty-with-shell.")
(defvar *pty-processes-lock* (sb-thread:make-mutex :name "pty ownership"))
(defun %string-non-empty-p (value) (and (stringp value) (plusp (length value))))
(defun %spawn-directory (start-dir)
  (when (%string-non-empty-p start-dir)
    (handler-case (truename start-dir) (file-error () nil))))
(defun %default-shell ()
  (let ((shell (sb-ext:posix-getenv "SHELL")))
    (if (%string-non-empty-p shell) shell "/bin/sh")))
(defun %target-program-and-args (default-command)
  (if (%string-non-empty-p default-command)
      (values "/bin/sh" (list "-c" default-command) nil)
      (let ((shell (%default-shell)))
        (values shell nil (not (char= (char shell 0) #\/))))))
(defun %remember-pty-process (master-fd pty)
  (sb-thread:with-mutex (*pty-processes-lock*)
    (setf (gethash master-fd *pty-processes*) pty)))
(defun %take-pty-process (master-fd &optional child-pid)
  (sb-thread:with-mutex (*pty-processes-lock*)
    (let ((pty (gethash master-fd *pty-processes*)))
      (when (and pty (or (null child-pid)
                         (= child-pid (cl-tty-kit:pty-pid pty))))
        (remhash master-fd *pty-processes*)
        pty))))
(defparameter +pty-child-wait-timeout+ (cl-date-kit:duration-of-seconds 5))
(defconstant +pty-write-timeout-seconds+ 2)
(defun pty-child-exit-status (master-fd &optional (timeout +pty-child-wait-timeout+))
  (let* ((pty (gethash master-fd *pty-processes*))
         (process (and pty (cl-tty-kit:pty-process pty))))
    (when process
      (handler-case
          (progn
            (cl-concurrent-kit:with-timeout timeout (sb-ext:process-wait process))
            (let ((code (sb-ext:process-exit-code process)))
              (when code
                (if (eq (sb-ext:process-status process) :signaled)
                    (values nil :signaled) (values code :exited)))))
        (cl-concurrent-kit:operation-timed-out () nil) (error () nil)))))
(defun %restore-cooked-termios (master-fd)
  "Give the PTY behind MASTER-FD the ordinary interactive line discipline.
   SBCL's run-program runs set_noecho (runtime/run-program.c) in the child
   before exec, which clears ECHO on the slave: without this the user sees
   nothing of what they type and readline stops echoing history recall too.
   tcsetattr on the master reaches the same termios as the slave, and the
   parent only gets here after the child has exec'd (wait-for-exec), so the
   child cannot clear ECHO again afterwards.  A child that died before this
   runs leaves the master with no slave open, hence the syscall guard."
  (handler-case
      (let ((termios (sb-posix:tcgetattr master-fd)))
        (setf (sb-posix:termios-lflag termios)
              (logior (sb-posix:termios-lflag termios)
                      sb-posix:icanon sb-posix:echo sb-posix:echoe
                      sb-posix:echok sb-posix:isig)
              (sb-posix:termios-iflag termios)
              (logior (sb-posix:termios-iflag termios) sb-posix:icrnl)
              (sb-posix:termios-oflag termios)
              (logior (sb-posix:termios-oflag termios) sb-posix:opost))
        (sb-posix:tcsetattr master-fd sb-posix:tcsanow termios)
        t)
    (sb-posix:syscall-error () nil)))

(defun forkpty-with-shell (rows cols &key start-dir default-command environment)
  (declare (type fixnum rows cols))
  (multiple-value-bind (program args search-p) (%target-program-and-args default-command)
    (declare (ignore search-p))
    (let ((pty (cl-tty-kit:make-pty :program program :args args :environment environment
                                    :directory (%spawn-directory start-dir)))
          (success nil))
      (unwind-protect
           (let ((master (cl-tty-kit:pty-fd pty)) (pid (cl-tty-kit:pty-pid pty)))
             (set-pty-size master rows cols) (%restore-cooked-termios master)
             (%remember-pty-process master pty)
             (setf success t) (values master pid ""))
        (unless success
          (handler-case (cl-tty-kit:close-pty pty)
            (cl-tty-kit:pty-operation-failed () nil)))))))
(defun %signal-owned-process (process signal)
  (sb-sys:without-interrupts
    (sb-thread:with-mutex (sb-impl::*active-processes-lock*)
      (unless (or (sb-impl::process-closed-p process)
                  (member (sb-impl::process-%status process) '(:exited :signaled)))
        (sb-ext:process-kill process signal)))))

(defun %terminate-owned-process (process)
  (%signal-owned-process process sb-posix:sighup)
  (loop repeat 20
        until (member (sb-ext:process-status process) '(:exited :signaled))
        do (sleep 0.01))
  (%signal-owned-process process sb-posix:sigkill)
  (let ((master (sb-ext:process-pty process)))
    (when master (close master :abort t)))
  (sb-ext:process-wait process)
  (values (sb-ext:process-exit-code process) (sb-ext:process-status process)))

(defun pty-close (master-fd child-pid)
  (when (>= master-fd 0)
    (let ((pty (%take-pty-process master-fd child-pid)))
      (cond
        (pty
         (let ((process (cl-tty-kit:pty-process pty)))
           (multiple-value-prog1
               (handler-case (%terminate-owned-process process)
                 (error (condition)
                   (%remember-pty-process master-fd pty)
                   (error condition)))
             (handler-case (sb-ext:process-close process)
               (stream-error () nil)
               (file-error () nil)))))
        ((not (plusp child-pid))
         (handler-case (sb-posix:close master-fd)
           (sb-posix:syscall-error () nil)))))))

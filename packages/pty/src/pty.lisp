(in-package #:nerimux/pty)

(defun set-pty-size (master-fd rows cols)
  (cl-tty-kit:set-terminal-size cols rows master-fd))

(defun install-pty-port ()
  (setf nerimux/ports:*spawn-pty* #'forkpty-with-shell
        nerimux/ports:*write-pty* #'pty-write
        nerimux/ports:*resize-pty* #'set-pty-size
        nerimux/ports:*close-pty* #'pty-close))

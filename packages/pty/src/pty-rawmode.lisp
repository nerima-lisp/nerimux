(in-package #:nerimux/pty)

(defun enable-raw-mode! (fd)
  "Switch FD to raw (unbuffered, no-echo) mode via cl-tty-kit:enable-raw-mode,
   which remembers the previous settings keyed by FD."
  (cl-tty-kit:enable-raw-mode fd))

(defun disable-raw-mode! (fd)
  "Restore the terminal settings saved by enable-raw-mode! for FD via
   cl-tty-kit:disable-raw-mode."
  (cl-tty-kit:disable-raw-mode fd))

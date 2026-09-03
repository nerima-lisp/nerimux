(in-package #:nerimux/ports)

(defvar *spawn-pty*
  nil
  "Function (rows cols &key start-dir default-command environment) → (values fd pid tty).
   Installed by nerimux/pty:install-pty-port.")

(defvar *write-pty*
  nil
  "Function (fd bytes) → nil.
   Installed by nerimux/pty:install-pty-port.")

(defvar *resize-pty*
  nil
  "Function (fd rows cols) → nil.
   Installed by nerimux/pty:install-pty-port.")

(defvar *close-pty*
  nil
  "Function (fd pid) → nil.
   Installed by nerimux/pty:install-pty-port.")

(defun spawn-pty (rows cols &key start-dir default-command environment)
  "Spawn a PTY-backed shell process. Returns (values fd pid slave-path)."
  (funcall *spawn-pty*
           rows
           cols
           :start-dir
           start-dir
           :default-command
           default-command
           :environment
           environment))

(defun write-pty (fd bytes)
  "Write BYTES to PTY file descriptor FD."
  (funcall *write-pty* fd bytes))

(defun resize-pty (fd rows cols)
  "Resize the PTY at FD to ROWS x COLS."
  (funcall *resize-pty* fd rows cols))

(defun close-pty (fd pid)
  "Close PTY master FD and signal child PID."
  (funcall *close-pty* fd pid))

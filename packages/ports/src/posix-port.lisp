(in-package #:nerimux/ports)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defconstant +pty-buf-size+
  4096
  "Byte buffer size for PTY reads.")

(defconstant +poll-timeout-us+
  50000
  "Select timeout in microseconds for stdin/socket polling (50 ms, so roughly a
   20 fps ceiling on how fast a keystroke can be noticed).")

(defconstant +pty-poll-timeout-us+
  50000
  "Select timeout in microseconds for per-pane PTY reader threads (50 ms).
   Bounded so the reader loop observes *RUNNING* even when the shell is silent.")

(defun find-posix-function (name)
  "The fbound SB-POSIX function named NAME, or NIL when unavailable."
  (let ((symbol (find-symbol name "SB-POSIX")))
    (when (and symbol (fboundp symbol))
      symbol)))

(defun environment-value (name)
  "Value of environment variable NAME in this process, or NIL when unset."
  (sb-ext:posix-getenv name))

(defun environment-entries ()
  "The process environment as a list of \"NAME=VALUE\" strings, or NIL."
  (sb-ext:posix-environ))

(defun working-directory ()
  "This process's current working directory."
  (sb-posix:getcwd))

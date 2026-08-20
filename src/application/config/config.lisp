(in-package #:nerimux/config)

;;; ── Shell default ─────────────────────────────────────────────────────────
;;;
;;; *default-shell* starts as "/bin/sh".  The ORCHESTRATE layer (main.lisp)
;;; calls init-default-shell at startup to read $SHELL from the environment.
;;; This keeps the DATA-layer defparameter free of I/O side-effects.

(defparameter *default-shell* "/bin/sh"
  "Shell binary launched for new panes.")

(defun init-default-shell ()
  "Set *DEFAULT-SHELL* from $SHELL if that variable is set and non-empty.
   Call this once at program startup (in main.lisp) before spawning any panes."
  (let ((shell (sb-ext:posix-getenv "SHELL")))
    (when (and shell (plusp (length shell)))
      (setf *default-shell* shell))))

(defconstant +pty-buf-size+ 4096
  "Byte buffer size for PTY reads.")

(defconstant +max-scrollback-lines+ 1000
  "Maximum rows retained in the per-pane scrollback buffer.")

(defconstant +poll-timeout-us+ 50000
  "Select timeout in microseconds for stdin/socket polling (50 ms ≈ 20 fps max).")

(defconstant +accept-timeout-us+ 100000
  "Select timeout in microseconds for the server accept-connection loop (100 ms).
   Prevents blocking forever so *running* is checked between connection attempts.")

(defconstant +pty-poll-timeout-us+ 50000
  "Select timeout in microseconds for per-pane PTY reader threads (50 ms).
   Allows the reader loop to observe *running* even when the shell is silent.")

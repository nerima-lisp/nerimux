(in-package #:nerimux/config)

;;; ── Shell default ─────────────────────────────────────────────────────────
;;;
;;; The shell to launch lives in the `default-shell' option and nowhere else.
;;; There used to be a *default-shell* variable beside it that every writer
;;; updated and every reader read, leaving the option itself inert -- so
;;; `set-shell' could change the real shell while show-options still reported
;;; the old one.  init-default-shell now writes the option like any other
;;; configuration source; run-server calls it before loading the config file,
;;; so a default-shell line still wins over $SHELL.

(defun init-default-shell ()
  "Set the `default-shell' option from $SHELL when that variable is non-empty.
   Called once from run-server, before the config file is loaded."
  (let ((shell (sb-ext:posix-getenv "SHELL")))
    (when (and shell (plusp (length shell)))
      (nerimux/options:set-option "default-shell" shell))))

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

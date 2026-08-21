;;; Domain abstraction packages.

(defpackage #:nerimux/ports
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the PTY port, one half of the dependency inversion that keeps the
    model free of the operating system.  Holds the *spawn-pty* / *write-pty* /
    *resize-pty* / *close-pty* function cells that nerimux/model calls, and that the
    INFRASTRUCTURE package nerimux/pty fills in via install-pty-port at server or
    test setup time.")
  (:export
   ;; I/O tuning for the descriptor-level read and select loops. These lived in
   ;; nerimux/config, which made every reader of them depend upward on the
   ;; application layer for three numbers that were never configurable.
   #:+pty-buf-size+
   #:+poll-timeout-us+
   #:+pty-poll-timeout-us+
   ;; POSIX symbol lookup, used by domain and application alike.
   #:find-posix-function
   ;; Process environment / cwd, named here so domain code does not scatter raw
   ;; SB-EXT calls.  Wrappers, not port variables -- see posix-port.lisp.
   #:environment-value
   #:environment-entries
   #:working-directory
   #:*spawn-pty*
   #:*write-pty*
   #:*resize-pty*
   #:*close-pty*
   #:spawn-pty
   #:write-pty
   #:resize-pty
   #:close-pty))

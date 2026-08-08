(in-package #:cl-tmux/pty)

;;;; Platform constants for the PTY subsystem.
;;;;
;;;; This file is pure data: no side effects, no I/O, no process operations.
;;;;
;;;; It used to declare cl-tmux's own C surface as well — a select(2) defcfun,
;;;; a struct winsize, the TIOCGWINSZ/TIOCSWINSZ request numbers, and hand-rolled
;;;; FD_ZERO/FD_SET/FD_ISSET bit twiddling over a foreign :uint32 array. All of
;;;; that is gone, and with it cl-tmux's last use of cffi:
;;;;
;;;;   * select(2)          -> process-kit:select-fds / wait-for-input, which
;;;;                           additionally retries EINTR against a fixed
;;;;                           deadline and rejects fd >= FD_SETSIZE instead of
;;;;                           writing past the end of the bitmap.
;;;;   * ioctl(TIOCSWINSZ)  -> cl-tty-kit:set-terminal-size.
;;;;   * ioctl(TIOCGWINSZ)  -> cl-tty-kit:terminal-size (already delegated).
;;;;   * kill(2)            -> sb-posix:kill.
;;;;   * read(2)/write(2)   -> cl-tty-kit:fd-read-octets / fd-write-octets
;;;;                           (delegated in an earlier change).

;;; ── Load sb-posix ──────────────────────────────────────────────────────────
;;;
;;; Loaded here, in the first file of the module, because pty.lisp calls
;;; sb-posix:kill and sb-posix:close. sb-posix ships with SBCL and is not an
;;; external dependency (DEPENDENCY_POLICY.md).

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

;;; ── Platform constants ─────────────────────────────────────────────────────

;;; Standard file descriptor numbers
(defconstant +stdout-fd+ 1 "Standard output.")

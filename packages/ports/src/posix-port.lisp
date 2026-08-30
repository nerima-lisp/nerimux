(in-package #:nerimux/ports)

;;;; SBCL is the supported runtime.  Load SB-POSIX here because this early port
;;;; owns the syscall-error boundary for working-directory and environment ops.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

;;;; POSIX symbol lookup for optional symbols within the supported SBCL runtime.

;;; I/O tuning for the descriptor-level loops.
;;;
;;; These were defined in nerimux/config, next to the config-file loader, which
;;; made a PTY reader thread and a select loop depend upward on the application
;;; layer for three numbers no config file could ever change. They are properties
;;; of the read/select boundary, so they live at that boundary now.
;;;
;;; A fourth, +accept-timeout-us+, went with the move: it had no caller left once
;;; the accept loop became part of the select-multiplexed iteration.

(defconstant +pty-buf-size+ 4096
  "Byte buffer size for PTY reads.")

(defconstant +poll-timeout-us+ 50000
  "Select timeout in microseconds for stdin/socket polling (50 ms, so roughly a
   20 fps ceiling on how fast a keystroke can be noticed).")

(defconstant +pty-poll-timeout-us+ 50000
  "Select timeout in microseconds for per-pane PTY reader threads (50 ms).
   Bounded so the reader loop observes *RUNNING* even when the shell is silent.")

(defun find-posix-function (name)
  "The fbound SB-POSIX function named NAME, or NIL when unavailable."
  (let ((symbol (find-symbol name "SB-POSIX")))
    (when (and symbol (fboundp symbol))
      symbol)))

;;; ── Process environment and working directory ────────────────────────────────
;;;
;;; Thin wrappers, deliberately NOT port variables.  The pty port is a variable
;;; because it has two implementations -- a real adapter and a test fake -- and
;;; the fake is genuinely exercised.  "Read my own process's
;;; environment" has exactly one implementation and always will: the tests that
;;; cover these paths stub by mutating the REAL environment
;;; (packages/ports/tests/helpers-posix-environment.lisp),
;;; not by installing a fake.  A *getenv* variable would be dead abstraction from
;;; the day it was written, and an uninstalled one would reproduce the failure
;;; mode this codebase keeps hitting: a port nobody binds, whose fallback
;;; succeeds silently.
;;;
;;; What these DO buy is one place that names the dependency, so a reader of
;;; domain/model and domain/format sees a named capability rather than a raw
;;; SB-EXT call scattered across six files.

(defun environment-value (name)
  "Value of environment variable NAME in this process, or NIL when unset."
  (sb-ext:posix-getenv name))

(defun environment-entries ()
  "The process environment as a list of \"NAME=VALUE\" strings, or NIL."
  (sb-ext:posix-environ))

(defun working-directory ()
  "This process's current working directory."
  (sb-posix:getcwd))

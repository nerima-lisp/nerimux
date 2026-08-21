(in-package #:nerimux/ports)

;;;; POSIX symbol lookup.
;;;;
;;;; Domain code must not depend on SB-POSIX being present, and must not reach
;;;; up into the application layer to ask.  This resolves an SB-POSIX function
;;;; by name at CALL time -- deferred, so a load-time defvar cannot capture NIL
;;;; before the package exists -- and returns NIL when the implementation does
;;;; not offer it, leaving the caller to decide what a missing syscall means.
;;;;
;;;; It lived in nerimux/config, which made every domain caller depend upward on
;;;; application for a pure reflection helper.  Its application-side callers now
;;;; depend downward on this package instead, which is the direction the layering
;;;; rule allows.

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
  "The SB-POSIX function named NAME, or NIL when SB-POSIX is absent or does not
   export it.  NAME is a string, e.g. \"SETENV\"."
  (let ((package (find-package "SB-POSIX")))
    (and package (find-symbol name package))))

;;; ── Process environment and working directory ────────────────────────────────
;;;
;;; Thin wrappers, deliberately NOT port variables.  The pty port is a variable
;;; because it has two implementations -- a real adapter and a test fake -- and
;;; the fake is genuinely exercised.  "Read my own process's
;;; environment" has exactly one implementation and always will: the tests that
;;; cover these paths stub by mutating the REAL environment
;;; (t/helpers-overlay-assertions.lisp's with-temporary-posix-environment-variable),
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
  (ignore-errors (sb-ext:posix-getenv name)))

(defun environment-entries ()
  "The process environment as a list of \"NAME=VALUE\" strings, or NIL."
  (ignore-errors (sb-ext:posix-environ)))

(defun working-directory ()
  "This process's current working directory, or NIL when unavailable.

   Resolved through FIND-POSIX-FUNCTION rather than called directly: getcwd
   lives in SB-POSIX, which needs (require :sb-posix).  run-server does that at
   startup, but a REPL or a test harness that never calls run-server would hit
   an undefined function instead.  This is the same treatment
   process-set-environment already gives SETENV/UNSETENV."
  (let ((getcwd (find-posix-function "GETCWD")))
    (and getcwd (ignore-errors (funcall getcwd)))))

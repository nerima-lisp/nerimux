;;; Startup mode dispatch and CLI entry point.
;;;
;;; Socket discovery/server auto-start helpers live in main-startup-socket.lisp.
;;; Command handlers live in main-startup-commands.lisp.
;;; This file owns the binary entry-point dispatch.

(in-package :nerimux)

(defun %application-argv ()
  "Return nerimux application arguments from SBCL's process argv.
   The Nix wrapper starts the saved core as `sbcl --core ... --no-userinit ...`;
   in that shape SBCL runtime options can appear before the real nerimux command."
  (let* ((argv (rest sb-ext:*posix-argv*))
         (marker (or (position "--no-userinit" argv :test #'string= :from-end t)
                     (position "--end-toplevel-options" argv :test #'string= :from-end t))))
    (if marker
        (nthcdr (1+ marker) argv)
        argv)))

(defun %parse-global-cli-argv (argv)
  "Parse ARGV (the application argv, without the argv0 slot) against *cli-app*
   (main-startup-flags.lisp).  Returns the parser invocation, or NIL and
   prints a usage error to *error-output* when ARGV is malformed."
  (handler-case
      (cl-cli:parse-argv *cli-app* (cons "nerimux" argv))
    (cl-cli:cli-usage-error (c)
      (format *error-output* "~&nerimux: ~A~%" c)
      (write-string (%usage-string) *error-output*)
      nil)))

(defun %apply-global-cli-invocation (invocation)
  "Return INVOCATION's remaining :mode-args rest positional — the mode word
   plus its own args.  INVOCATION carries no other global options; -V and -h
   are the only global flags and are handled by
   %dispatch-global-cli-flag-actions."
  (cl-cli:positional-value invocation :mode-args))

(defun %dispatch-global-cli-flag-actions (invocation mode-args)
  "Run the flag-driven entry points that today double as *startup-modes* mode
   names (-V/-h), so they work regardless of where they appear in argv.
   Returns T when one of them ran (the caller must not also dispatch a mode)."
  (cond
    ((cl-cli:option-value invocation :print-version) (run-version nil) t)
    ((cl-cli:option-value invocation :print-help)    (run-usage nil)   t)
    (t nil)))

(defun main ()
  "Binary entry point - dispatches on the first argv item via *startup-modes*.
   The global flags -V and -h are parsed by *cli-app* (cl-cli, see
   main-startup-flags.lisp) from anywhere in the leading flag run, in any
   order, before mode dispatch.
   Each entry in *startup-modes* is a plist (handler-symbol &key :raw-args-p).
   :raw-args-p T modes receive the full argv tail; all others receive a single
   session name (defaulting to \"0\").
   An unrecognized or absent mode is a usage error (%dispatch-unknown-mode).
   Any ERROR signaled by mode dispatch is caught here and reported the same way
   %parse-global-cli-argv already reports a malformed global flag: a one-line
   message on *error-output* and exit 1 — never the raw SBCL debugger, which
   the saved core would otherwise drop a real user into."
  (let ((invocation (%parse-global-cli-argv (%application-argv))))
    (if (null invocation)
        (sb-ext:exit :code 1)
        (let ((mode-args (%apply-global-cli-invocation invocation)))
          (unless (%dispatch-global-cli-flag-actions invocation mode-args)
            (let* ((mode  (first mode-args))
                   (rest  (rest mode-args))
                   (entry (cdr (assoc mode *startup-modes* :test #'equal))))
              (handler-case
                  (%dispatch-startup-mode-entry entry mode rest)
                (error (c)
                  (format *error-output* "~&nerimux: ~A~%" c)
                  (sb-ext:exit :code 1)))))))))

(defun %dispatch-unknown-mode (mode rest)
  "Handle an argv whose first item is not a known startup mode.
   Every case is a usage error now: print the summary to stderr and exit 1.

   This used to have two other branches.  A recognized-looking command word was
   forwarded to a running server as a command client, and a bare `nerimux` with
   no arguments started the standalone in-process multiplexer.  Both belonged
   to the removed command-forwarding surface: the forwarding branch is what
   actually made `nerimux list-sessions` work, independently of the
   *startup-modes* table, so removing the table entries alone would not have
   removed the capability.
   The entry surface is now `attach`, `server`, and `kill` (1.6, R8.1), and
   anything else — including no argument at all — is rejected rather than
   guessed at."
  (declare (ignore rest))
  (declare (ignorable mode))
  (write-string (%usage-string) *error-output*)
  (sb-ext:exit :code 1))

(defun %dispatch-startup-mode-entry (entry mode rest)
  (if entry
      (%dispatch-startup-mode-handler entry mode rest)
      (%dispatch-unknown-mode mode rest)))

(defun %dispatch-startup-mode-handler (entry mode rest)
  (let ((handler    (first entry))
        (raw-args-p (%startup-mode-raw-args-p mode)))
    ;; Dispatch: :raw-args-p modes receive the full tail; name-only modes
    ;; receive a single session name so their signature stays (name).
    (if raw-args-p
        (funcall (symbol-function handler) rest)
        (funcall (symbol-function handler) (or (first rest) "0")))))

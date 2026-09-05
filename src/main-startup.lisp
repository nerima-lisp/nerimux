(in-package :nerimux)

(defun %application-argv ()
  "Return nerimux application arguments from SBCL's process argv.
   The Nix wrapper starts the saved core as `sbcl --core ... --no-userinit ...`;
   in that shape SBCL runtime options can appear before the real nerimux command."
  (let* ((argv (rest sb-ext:*posix-argv*))
         (marker
          (or (position "--no-userinit" argv :test #'string= :from-end t)
              (position "--end-toplevel-options"
                        argv
                        :test
                        #'string=
                        :from-end
                        t))))
    (if marker
        (nthcdr (1+ marker) argv)
        argv)))

(defun %parse-global-cli-argv (argv)
  "Parse ARGV (the application argv, without the argv0 slot) against *cli-app*
   (main-startup-flags.lisp).  Returns the parser invocation, or NIL and
   prints a usage error to *error-output* when ARGV is malformed."
  (handler-case (cl-cli:parse-argv *cli-app* (cons "nerimux" argv))
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

(defun %dispatch-global-cli-flag-actions (invocation)
  "Run the flag-driven entry points that today double as *startup-modes* mode
   names (-V/-h), so they work regardless of where they appear in argv.
   Returns T when one of them ran (the caller must not also dispatch a mode)."
  (cond
    ((cl-cli:option-value invocation :print-version)
      (run-version nil)
      t)
    ((cl-cli:option-value invocation :print-help)
      (run-usage nil)
      t)
    (t nil)))

(defun main ()
  "Binary entry point - dispatches on the first argv item via *startup-modes*.
   The global flags -V and -h are parsed by *cli-app* (cl-cli, see
   main-startup-flags.lisp) from anywhere in the leading flag run, in any
   order, before mode dispatch.
   Each entry in *startup-modes* is a plist (handler-symbol &key :raw-args-p).
   :raw-args-p T modes receive the full argv tail; all others receive a single
   session name (defaulting to \"0\").
   An unrecognized mode is a usage error (%dispatch-unknown-mode); a bare
   `nerimux` with no argument at all defaults to `attach` instead (FR-001) --
   see %dispatch-startup-mode-entry.
   Any ERROR signaled by mode dispatch is caught here and reported the same way
   %parse-global-cli-argv already reports a malformed global flag: a one-line
   message on *error-output* and exit 1 — never the raw SBCL debugger, which
   the saved core would otherwise drop a real user into."
  (let ((*print-circle* t)
        (invocation (%parse-global-cli-argv (%application-argv))))
    (if (null invocation)
        (sb-ext:exit :code 1)
        (let ((mode-args (%apply-global-cli-invocation invocation)))
          (unless (%dispatch-global-cli-flag-actions invocation)
            (let* ((mode  (first mode-args))
                   (rest  (rest mode-args))
                   (entry (cdr (assoc mode *startup-modes* :test #'equal))))
              (handler-case
                  (%dispatch-startup-mode-entry entry mode rest)
                ((or error sb-ext:timeout) (c)
                  (format *error-output* "~&nerimux: ~A~%" c)
                  (sb-ext:exit :code 1)))))))))

(defun %dispatch-unknown-mode (mode rest)
  "Handle an argv whose first item is not a known startup mode.
   Every case is a usage error: print the summary to stderr and exit 1."
  (declare (ignore rest))
  (declare (ignorable mode))
  (write-string (%usage-string) *error-output*)
  (sb-ext:exit :code 1))

(defun %dispatch-startup-mode-entry (entry mode rest)
  "Dispatch ENTRY (looked up from MODE in *startup-modes*) with its REST argv.
   A recognized MODE with no ENTRY -- an unknown mode word -- is a usage error.
   MODE itself NIL (argv had no first item at all, i.e. a bare `nerimux`) is
   not that case: it defaults to `attach` (FR-001) at its own name-only
   convention, (or (first rest) \"0\") -- REST is NIL here too, so this is
   always the default session \"0\" -- rather than falling through to
   %dispatch-unknown-mode."
  (cond
    (entry (%dispatch-startup-mode-handler entry mode rest))
    (mode  (%dispatch-unknown-mode mode rest))
    (t     (%dispatch-startup-mode-handler (%startup-mode-entry "attach")
                                           "attach" rest))))

(defun %dispatch-startup-mode-handler (entry mode rest)
  (let ((handler    (first entry))
        (raw-args-p (%startup-mode-raw-args-p mode)))
    (if raw-args-p
        (funcall (symbol-function handler) rest)
        (funcall (symbol-function handler) (or (first rest) "0")))))

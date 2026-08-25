;;; Startup command handlers.
;;;
;;; The entry surface is `attach`, `server`, `kill`, and the version/usage
;;; flags (1.6).  Every other startup mode belonged to the removed
;;; command-forwarding layer: modes such as new-session, has-session,
;;; kill-server, list-*, show-*, display-message, and source-file sent a
;;; command name over the socket to a server-side command table, and
;;; attach-session existed only for their flag parsing.  They were removed
;;; along with that table; main-startup.lisp rejects an unrecognized word
;;; rather than forwarding it.  `kill` (R8.1) is new, not revived: it talks
;;; to the server over the same +msg-command+ channel worktree commands
;;; already use the multi-dispatch command handlers, not that removed table.
;;;
;;; main-startup.lisp keeps argv parsing and dispatch.

(in-package :nerimux)

(defun %attach-session (name &key target)
  "Ensure NAME's server is running, then attach the client."
  (%ensure-server-running name)
  (if target
      (run-client name :target target)
      (run-client name)))

(defun %workspace-attach-target-p (name)
  (and (stringp name)
       (plusp (length name))
       (or (char= (char name 0) #\/) (find #\/ name))))

(defun run-attach-simple (name)
  "Auto-start a server for NAME if not running, then attach as a client.
   This is the handler for the bare 'attach' mode (no flag parsing).  A path or
   slash-qualified selector attaches to the default workspace server and is
   resolved by the server against the current catalog."
  (if (%workspace-attach-target-p name)
      (%attach-session "0" :target name)
      (%attach-session name)))

(defun run-version (raw-args)
  "Print the nerimux version to stdout and exit 0."
  (declare (ignore raw-args))
  (format t "nerimux ~A~%" (nerimux/version:version-string))
  (sb-ext:exit :code 0))

;;; ── nerimux kill (R8.1) ──────────────────────────────────────────────────

(defun %kill-force-p (rest)
  "True when REST -- kill's own argv tail, e.g. (\"--force\") -- asks for
   --force.  kill is a :raw-args-p startup mode (see *startup-modes* below)
   specifically so this flag is parsed here rather than by *cli-app*: 1.6/
   R1.17 fix the global flags at -V/-h only, and --force is kill's own
   argument, not a global one."
  (and (member "--force" rest :test #'string=) t))

(defun run-kill (rest)
  "CLI entry point for `nerimux kill [--force]` (R8.1): ask the server at
   the fixed session name (\"0\" -- R1.5 fixes the session to one) to shut
   down over its socket (send-kill-request, client.lisp).  A plain
   `nerimux kill` is refused, printing the still-open panes and exiting 1,
   when any pane is alive; --force tells the server to SIGHUP then SIGKILL
   them first.
   No server running at all is not handled here: send-kill-request's
   connection failure propagates as an ERROR, caught by main()'s top-level
   handler-case the same way every other startup error is."
  (multiple-value-bind (status text)
      (send-kill-request "0" (%kill-force-p rest))
    (case status
      (:ok (sb-ext:exit :code 0))
      (:denied
       (format *error-output*
               "~&nerimux: kill refused, panes still open:~%~A~%~
                nerimux: retry with --force to close them~%"
               text)
       (sb-ext:exit :code 1))
      (t
       (format *error-output* "~&nerimux: kill: no reply from server~%")
       (sb-ext:exit :code 1)))))

(defun %usage-string ()
  "One-page usage summary for -h/--help and bad-flag errors."
  (format nil "usage: nerimux [command]~%~
               ~%~
               Commands:~%~
               ~2Tattach [selector]~26Topen the workspace UI (auto-starts a server)~%~
               ~2Tserver [name]~26Trun a headless server owning session NAME~%~
               ~2Tkill [--force]~26Tstop the running server (refuses if panes are open)~%~
               ~2T-V | --version~26Tprint the version and exit~%~
               ~2T-h | --help~26Tprint this summary and exit~%~
               ~%~
               A selector containing a slash resolves as an~%~
               organization/repository selector or a local worktree path.~%"))

(defun run-usage (raw-args)
  "Print the usage summary to stdout and exit 0 (-h/--help)."
  (declare (ignore raw-args))
  (write-string (%usage-string))
  (sb-ext:exit :code 0))

(defmacro %startup-mode (mode-name handler &key raw-args-p)
  `(cons ,mode-name
         (list ',handler
               ,@(when raw-args-p
                   '(:raw-args-p t)))))

;;; ── Startup mode dispatch (data / logic separation) ─────────────────────────
;;;
;;; *startup-modes* is the DATA: a map from mode-name strings to handler
;;; functions.  main is the LOGIC: it looks up the mode and dispatches.
;;;
;;; Each handler is a symbol so test stubs that rebind the function cell with
;;; SETF FDEFINITION are honoured at dispatch time.
;;;
;;; Handlers that need RAW-ARGS (the full argv tail) receive them directly.
;;; Handlers that need only a session NAME extract (or (first rest) "0")
;;; outside the handler - this is the one-argument convention.

(defparameter *startup-modes*
  (list (%startup-mode "server" run-server)
        (%startup-mode "attach" run-attach-simple)
        ;; kill (R8.1) is :raw-args-p so run-kill sees --force itself; it is
        ;; kill's own argument (1.6), not parsed by *cli-app*'s global flags.
        (%startup-mode "kill" run-kill :raw-args-p t)
        ;; -V: print the version and exit. --version/-h/--help are
        ;; nerimux's own conventions for the same flags.
        (%startup-mode "-V" run-version :raw-args-p t)
        (%startup-mode "--version" run-version :raw-args-p t)
        (%startup-mode "-h" run-usage :raw-args-p t)
        (%startup-mode "--help" run-usage :raw-args-p t))
  "Mode-name -> plist dispatch table for the binary entry point.
   Each entry is (mode-name . (handler-symbol &key :raw-args-p bool)).
   :raw-args-p T means the handler receives the full raw argv tail rather
   than a single session name.")

(defun %startup-mode-entry (mode-name)
  (cdr (assoc mode-name *startup-modes* :test #'equal)))

(defun %startup-mode-raw-args-p (mode-name)
  (getf (rest (%startup-mode-entry mode-name)) :raw-args-p))

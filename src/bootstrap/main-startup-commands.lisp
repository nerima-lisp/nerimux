;;; Startup command handlers.
;;;
;;; The entry surface is `attach`, `server`, and the version/usage flags.
;;; Every other startup mode belonged to the tmux compatibility layer: the
;;; command-forwarding modes (new-session, has-session, kill-server, list-*,
;;; show-*, display-message, source-file) sent a command name over the socket to
;;; the server's tmux command table, and attach-session existed for its flag
;;; parsing.  They were removed with that layer; main-startup.lisp rejects an
;;; unrecognized word rather than forwarding it.
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
  "Print the nerimux version to stdout and exit 0 (the tmux -V behaviour)."
  (declare (ignore raw-args))
  (format t "nerimux ~A~%" (nerimux/version:version-string))
  (sb-ext:exit :code 0))

(defun %usage-string ()
  "One-page usage summary for -h/--help and bad-flag errors."
  (format nil "usage: nerimux [command]~%~
               ~%~
               Commands:~%~
               ~2Tattach [selector]~26Topen the workspace UI (auto-starts a server)~%~
               ~2Tserver [name]~26Trun a headless server owning session NAME~%~
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
        ;; -V: print the version and exit (tmux -V). --version/-h/--help are
        ;; nerimux conveniences; tmux only prints usage on a bad flag.
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

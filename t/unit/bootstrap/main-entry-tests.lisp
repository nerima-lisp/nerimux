(in-package #:nerimux/test)

;;;; Tests for CLI entry point reachability and command forwarding.

;;; ── Coverage: stub handler functions ─────────────────────────────────────────
;;;
;;; sb-ext:exit terminates the process rather than signalling a condition.
;;; We stub it to capture the exit code for testing.

(defmacro with-stubbed-exit (code-var &body body)
  "Stub sb-ext:exit so it captures the :code argument in the existing variable
   CODE-VAR and non-locally exits the body via THROW (matching sb-ext:exit's
   declared return type of NIL — a returning stub triggers SIMPLE-CONTROL-ERROR).
   Assertions should follow the macro form, where CODE-VAR holds the captured
   value.  Uses WITHOUT-PACKAGE-LOCKS because SB-EXT is a locked package."
  (let ((tag     (gensym "EXIT-TAG"))
        (orig    (gensym "ORIG-EXIT")))
    `(sb-ext:without-package-locks
       (let ((,orig (fdefinition 'sb-ext:exit)))
         (setf (fdefinition 'sb-ext:exit)
               (lambda (&rest args &key (code 0) &allow-other-keys)
                 (declare (ignore args))
                 (setf ,code-var code)
                 (throw ',tag nil)))
         (unwind-protect
              (catch ',tag ,@body)
           (setf (fdefinition 'sb-ext:exit) ,orig))))))

(defmacro with-stubbed-server (server-name (forwarded-var exit-code-var) &body body)
  "Stub %running-server-name → SERVER-NAME, run-command-client → captures FORWARDED-VAR.
   FORWARDED-VAR and EXIT-CODE-VAR are fresh bindings visible in BODY."
  `(let ((,forwarded-var nil)
         ,exit-code-var)
     (with-stubbed-fdefinition
         ((nerimux::%running-server-name
           (lambda (&optional preferred) (declare (ignore preferred)) ,server-name))
          (nerimux::run-command-client
           (lambda (name args) (setf ,forwarded-var (list name args)))))
       ,@body)))

(describe "main-suite"

  ;;; ── run-attach-simple and run-attach-with-flags reachability ─────────────────

  ;; run-attach-simple is defined as a function.
  (it "run-attach-simple-is-fbound"
    (expect (fboundp 'nerimux::run-attach-simple)))

  ;; run-attach-with-flags is defined as a function.
  (it "run-attach-with-flags-is-fbound"
    (expect (fboundp 'nerimux::run-attach-with-flags)))

  ;; Control mode (-C) was removed with the tmux compatibility surface. Both
  ;; entry points it had are gone: the "-C"/"control" *startup-modes* rows and
  ;; the :control cl-cli option that %dispatch-global-cli-flag-actions read.
  (it "control-mode-startup-modes-are-gone"
    (expect (null (nerimux::%startup-mode-entry "-C")))
    (expect (null (nerimux::%startup-mode-entry "control")))
    (expect (not (fboundp 'nerimux::run-control-mode))))

  ;; The above pins the tables; this pins the observable behaviour, which is
  ;; what a user actually hits.  -C is now rejected by cl-cli's global option
  ;; parser (main-startup-flags.lisp *cli-app* no longer declares it), so the
  ;; rejection happens inside %parse-global-cli-argv -- BEFORE
  ;; %dispatch-unknown-mode's dash-flag branch is reached.  Without this test,
  ;; re-registering -C as a cl-cli option pointing somewhere else would leave
  ;; the table assertions above green.
  (it "control-mode-flag-exits-with-usage"
    (let ((standalone-called nil)
          exit-code
          errout)
      (with-stubbed-fdefinition
          ((nerimux::run-standalone
            (lambda (&rest a) (declare (ignore a)) (setf standalone-called t))))
        (setf errout
              (with-output-to-string (*error-output*)
                (with-stubbed-exit exit-code
                  (let ((sb-ext:*posix-argv* (list "nerimux" "-C")))
                    (nerimux::main))))))
      (expect (eql 1 exit-code))
      (expect (search "usage: nerimux" errout) :to-be-truthy)
      (expect standalone-called :to-be-falsy)))

  ;; An unrecognised argv[0] (not a known startup mode, not a -flag) forwards
  ;; to a live default-session server as a command client, rather than
  ;; starting a standalone session — %dispatch-unknown-mode's middle branch,
  ;; previously untested (only the dash-flag-usage-error and no-server
  ;; standalone-fallback shapes are implied by other tests).
  (it "dispatch-unknown-mode-forwards-to-live-server"
    (with-temp-socket-path (path)
      ;; %dispatch-unknown-mode only probes for the socket file's existence
      ;; (the actual connection is delegated to run-command-client, stubbed
      ;; below), so an empty file at PATH is enough to simulate "a server is
      ;; already running".
      (with-open-file (out path :direction :output :if-does-not-exist :create))
      (let (forwarded (standalone-called nil))
        (with-stubbed-fdefinition
            ((nerimux::socket-path (lambda (name) (declare (ignore name)) path))
             (nerimux::run-command-client
              (lambda (name args) (setf forwarded (list name args))))
             (nerimux::run-standalone
              (lambda () (setf standalone-called t))))
          ;; "rename-window" is not itself a *startup-modes* entry (unlike
          ;; list-sessions/kill-server/etc., which main dispatches directly);
          ;; it can only reach a live server as a forwarded command.
          (let ((sb-ext:*posix-argv* (list "nerimux" "rename-window" "new-name")))
            (nerimux::main))
          (expect (equal (list "0" (list "rename-window" "new-name")) forwarded))
          (expect (null standalone-called))))))

  ;; Without a server, all client commands exit with code 1.
  (it "run-commands-exit-when-no-server"
    (dolist (row '((nerimux::run-kill-server         nil)
                    (nerimux::run-list-sessions        nil)
                    (nerimux::run-list-windows         nil)
                    (nerimux::run-display-message      ("-p" "hello"))
                    (nerimux::run-show-options         ("-g"))
                    (nerimux::run-show-window-options  ("-g"))))
      (destructuring-bind (fn args) row
        (let (exit-code)
          (with-stubbed-exit exit-code
            (funcall fn args))
          (expect (eql 1 exit-code))))))

  ;; Commands forward their name and args to an existing server and exit cleanly.
  (it "run-commands-forward-to-server"
    (dolist (row '(("0"    nerimux::run-kill-server         ("-q")
                            ("kill-server" "-q"))
                    ("work" nerimux::run-list-sessions        ("-F" "#{session_name}")
                            ("list-sessions" "-F" "#{session_name}"))
                    ("work" nerimux::run-list-windows         ("-F" "#{window_name}")
                            ("list-windows" "-F" "#{window_name}"))
                    ("work" nerimux::run-display-message      ("-p" "hello")
                            ("display-message" "-p" "hello"))
                    ("work" nerimux::run-show-options         ("-g")
                            ("show-options" "-g"))
                    ("work" nerimux::run-show-window-options  ("-g")
                            ("show-window-options" "-g"))))
      (destructuring-bind (server fn args expected-fwd) row
        (with-stubbed-server server (forwarded exit-code)
          (with-stubbed-exit exit-code
            (funcall fn args))
          (expect (equal (list server expected-fwd) forwarded))
          (expect (eql 0 exit-code))))))

  ;; run-new-session preserves tmux flags by forwarding the full argv to the server.
  (it "run-new-session-forwards-full-argv-when-server-exists"
    (let ((forwarded nil)
          (attached nil))
      (with-stubbed-fdefinition
          ((nerimux::%running-server-name
            (lambda (&optional preferred) (declare (ignore preferred)) "0"))
           (nerimux::run-command-client
            (lambda (name args) (setf forwarded (list name args))))
           (nerimux::run-client
            (lambda (&rest args) (setf attached args))))
        (nerimux::run-new-session '("-s" "work" "-n" "shell" "-c" "/tmp" "-d"))
        (expect (equal '("0" ("new-session" "-s" "work" "-n" "shell" "-c" "/tmp" "-d"))
                       forwarded))
        (expect (null attached)))))

  ;; run-new-session -s NAME creates a session in the existing server, not a new NAME socket.
  (it "run-new-session-discovers-existing-server-before-session-name"
    (let ((forwarded nil)
          (ensured nil)
          (probes '()))
      (with-stubbed-fdefinition
          ((nerimux::%running-server-name
            (lambda (&optional preferred)
              (push preferred probes)
              (and (null preferred) "alpha")))
           (nerimux::run-command-client
            (lambda (name args) (setf forwarded (list name args))))
           (nerimux::%ensure-server-running
            (lambda (name) (setf ensured name))))
        (nerimux::run-new-session '("-d" "-s" "beta" "-n" "two"))
        (expect (equal '("alpha" ("new-session" "-d" "-s" "beta" "-n" "two"))
                       forwarded))
        (expect (null ensured))
        (expect (equal '(nil) (reverse probes))))))

  ;; run-source-file with a nonexistent path exits 1 and writes tmux's diagnostic.
  (it "run-source-file-nonexistent-path-exits-1-with-diagnostic"
    (let (exit-code
          (output (make-string-output-stream)))
      (let ((*error-output* output)
            (nerimux::*message-log* nil))
        (with-stubbed-exit exit-code
          (nerimux::run-source-file (list "/nonexistent/no-such-file.conf"))))
      (expect (eql 1 exit-code))
      (let ((text (get-output-stream-string output)))
        (expect (search "No such file or directory: /nonexistent/no-such-file.conf"
                        text)))))

  ;; run-has-session with a nonexistent socket path exits with code 1.
  (it "run-has-session-no-socket-exits-1"
    (let (exit-code)
      (with-stubbed-exit exit-code
        (nerimux::run-has-session (list "-t" "no-such-session-xyz")))
      (expect (eql 1 exit-code))))

  ;; run-has-session with a socket FILE nothing listens on exits 1 — a stale
  ;; socket left by a crashed server is not a live session.
  (it "run-has-session-stale-socket-exits-1"
    (let ((nerimux::*socket-path-override*
            (format nil "~A/nerimux-has-session-stale-~D.sock"
                    (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                    (random 1000000)))
          exit-code)
      (unwind-protect
           (progn
             (with-open-file (s nerimux::*socket-path-override*
                                :direction :output :if-does-not-exist :create)
               (declare (ignore s)))
             (with-stubbed-exit exit-code
               (nerimux::run-has-session '("-t" "whatever")))
             (expect (eql 1 exit-code)))
        (ignore-errors (delete-file nerimux::*socket-path-override*)))))

  ;; CLI helper handlers are all fbound.
  (it "run-commands-are-fbound"
    (dolist (sym '(nerimux::run-kill-server
		 nerimux::run-list-sessions
		 nerimux::run-list-windows
		 nerimux::run-list-commands
		 nerimux::run-display-message
		 nerimux::run-show-options
		 nerimux::run-show-window-options
		 nerimux::run-source-file
		 nerimux::run-has-session))
      (expect (fboundp sym))))

  ;;; ── -V / --version / -h / --help / bad-flag usage ───────────────────────────

  ;; run-version prints "nerimux <version>" to stdout and exits 0.
  (it "run-version-prints-version-and-exits-zero"
    (let (exit-code output)
      (setf output
            (with-output-to-string (*standard-output*)
              (with-stubbed-exit exit-code
                (nerimux::run-version nil))))
      (expect (eql 0 exit-code))
      (expect (string= (format nil "nerimux ~A~%" (nerimux/version:version-string))
                       output))))

  ;; run-usage prints a usage summary to stdout and exits 0.
  (it "run-usage-prints-usage-and-exits-zero"
    (let (exit-code output)
      (setf output
            (with-output-to-string (*standard-output*)
              (with-stubbed-exit exit-code
                (nerimux::run-usage nil))))
      (expect (eql 0 exit-code))
      (expect (eql 0 (search "usage: nerimux" output)))))

  ;; argv -V/--version routes to run-version; -h/--help routes to run-usage.
  (it "dispatch-version-and-help-flags"
    (dolist (c '(("-V" :version) ("--version" :version)
                 ("-h" :usage)   ("--help" :usage)))
      (destructuring-bind (flag expected) c
        (let ((called nil))
          (with-stubbed-fdefinition
              ((nerimux::run-version
                (lambda (&rest a) (declare (ignore a)) (setf called :version)))
               (nerimux::run-usage
                (lambda (&rest a) (declare (ignore a)) (setf called :usage))))
            (let ((sb-ext:*posix-argv* (list "nerimux" flag)))
              (nerimux::main))
            (expect (eq expected called)))))))

  ;; An unknown dash-flag is a usage error (stderr + exit 1), not a silent
  ;; standalone start.
  (it "dispatch-unknown-dash-flag-prints-usage-and-exits-one"
    (let ((standalone-called nil)
          exit-code
          errout)
      (with-stubbed-fdefinition
          ((nerimux::run-standalone
            (lambda (&rest a) (declare (ignore a)) (setf standalone-called t))))
        (setf errout
              (with-output-to-string (*error-output*)
                (with-stubbed-exit exit-code
                  (let ((sb-ext:*posix-argv* (list "nerimux" "-Z")))
                    (nerimux::main))))))
      (expect (eql 1 exit-code))
      ;; cl-cli (main-startup-flags.lisp *cli-app*) now rejects -Z during global
      ;; flag parsing and prints its own diagnostic (e.g. "nerimux: Unknown
      ;; option...") before the usage block, so "usage: nerimux" no longer
      ;; starts at position 0 -- it just needs to be present.
      (expect (search "usage: nerimux" errout) :to-be-truthy)
      (expect standalone-called :to-be-falsy))))

  ;; A mode-specific flag-parser ERROR (e.g. new-session rejecting an
  ;; unsupported flag via %parse-new-session-flags) must be caught at main's
  ;; top level and reported as a clean stderr message + exit 1 -- never left
  ;; to propagate into the raw SBCL debugger the saved core would otherwise
  ;; drop a real user into. Found via a manual smoke test of the built
  ;; binary (`nerimux new-session -x 80` hit the debugger), see main's
  ;; handler-case.
  (it "unhandled-mode-error-prints-message-and-exits-one"
    (let (exit-code errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux" "new-session" "-x" "80")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (search "nerimux:" errout) :to-be-truthy)
      (expect (search "-x" errout) :to-be-truthy)))

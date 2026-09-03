(in-package #:nerimux/pane)

(defvar *pane-extra-env*
  nil
  "Dynamic variable: alist of (NAME . VALUE) pairs to set in the NEXT pane's
   child environment.  Bound by callers that need per-pane env vars (e.g.
   new-window -e VAR=val).  Consumed by %fork-pane and reset to NIL after use.")

(defvar +pane-term+
  "screen-256color"
  "TERM given to every pane's child process (§1.4: names the emulator's
   truecolor-capable screen entry; sgr.lisp:134-181 implements the 38/48/58;2
   sequences this advertises).")

(defparameter *pane-colorterm-env*
  (cons "COLORTERM" "truecolor")
  "COLORTERM entry merged into every pane's child environment (§1.4 / R2.5).")

(defun %spawn-pty-with-default-options (rows cols
                                             &key
                                             start-dir
                                             default-command
                                             environment)
  "Spawn a PTY shell at ROWS x COLS running DEFAULT-COMMAND (or the configured
   shell when NIL) with ENVIRONMENT as its child environment.
   Returns (values fd pid slave-path).  Shared by %fork-pane and respawn-pane.
   Calls the nerimux/ports:spawn-pty port (installed by install-pty-port)."
  (spawn-pty rows
             cols
             :start-dir
             start-dir
             :default-command
             default-command
             :environment
             environment))

(defun %spawn-shell-for-pane (session rows cols &key start-dir default-command extra-env)
  "Spawn a shell for a pane at COLS x ROWS, merging SESSION's environment overlay
   with *PANE-COLORTERM-ENV*, EXTRA-ENV, and the consumed *PANE-EXTRA-ENV*.
   DEFAULT-COMMAND, when non-NIL, is run via sh -c instead of the shell
   (§1.4: NIL is the default everywhere — the pane always starts a shell).
   Returns (values fd pid slave-path)."
  (let ((environment (nerimux/session:session-child-environment session
                                                 :term +pane-term+
                                                 :extra-env (list* *pane-colorterm-env*
                                                                   (append extra-env
                                                                           *pane-extra-env*)))))
    (setf *pane-extra-env* nil)
    (%spawn-pty-with-default-options rows cols
                                     :start-dir start-dir
                                     :default-command default-command
                                     :environment environment)))

(defun %fork-pane (session id x y cols rows &key start-dir default-command)
  "Spawn a shell and build a PTY-backed pane at position (X,Y) sized COLS x ROWS.
   COLS is the number of terminal columns; ROWS is the number of terminal rows.
   START-DIR: when non-NIL, the child shell is started in that directory.
   SESSION supplies the child environment overlay used for spawn.
   A split or new-window pane always starts the shell (§1.4: default-command
   is empty, and there is no configuration path left to change it).
   Extra environment variables may be injected via the *PANE-EXTRA-ENV* dynamic
   variable (alist of (NAME . VALUE)), which is consumed once and reset.
   Returns the new pane.  The PTY file descriptor and child PID are embedded
   in the pane struct; callers should call close-pty on them at teardown."
  (multiple-value-bind (fd pid slave-path) 
      (%spawn-shell-for-pane session
                             rows
                             cols
                             :start-dir
                             start-dir
                             :default-command
                             default-command)
    (make-pane :id
               id
               :x
               x
               :y
               y
               :width
               cols
               :height
               rows
               :fd
               fd
               :pid
               pid
               :tty
               (or slave-path "")
               :start-command
               (or default-command "")
               :start-path
               (or start-dir (nerimux/ports:working-directory) "")
               :screen
               (make-screen cols rows))))

(defun %make-input-pane (id x y w h)
  "Build a pane without a backing PTY, used by split-window -I."
  (make-pane :id
             id
             :x
             x
             :y
             y
             :width
             w
             :height
             h
             :fd
             -1
             :pid
             -1
             :tty
             ""
             :screen
             (make-screen w h)))

(defun respawn-pane (session pane &key start-dir default-command extra-env)
  "Restart PANE's PTY process, keeping geometry and screen intact.
   Closes the old PTY fd (sending SIGHUP to the child), spawns a fresh shell on
   a new PTY, and updates the pane's FD and PID.  The existing screen is
   preserved so the renderer can continue without a layout change.
   Returns the updated pane."
  (let ((old-fd  (pane-fd  pane))
        (old-pid (pane-pid pane))
        (cols    (pane-width  pane))
        (rows    (pane-height pane)))
    (close-pty old-fd old-pid)
    (multiple-value-bind (new-fd new-pid slave-path)
        (%spawn-shell-for-pane session rows cols
                               :start-dir start-dir
                               :default-command default-command
                               :extra-env extra-env)
      (setf (pane-fd pane) new-fd
            (pane-pid pane) new-pid
            (pane-tty pane) (or slave-path "")
            (pane-start-command pane) (or default-command "")
            (pane-start-path pane) (or start-dir
                                       (nerimux/ports:working-directory)
                                       "")
            (pane-unread-output-p pane) nil
            (pane-bell-p pane) nil
            (pane-process-exited-p pane) nil
            (pane-non-zero-exit-p pane) nil
            (pane-startup-failed-p pane) nil))
    pane))

;;; Startup socket discovery and server auto-start helpers.

(in-package :nerimux)

(defconstant +server-socket-poll-interval-seconds+ 0.1
  "Seconds between socket-existence probes while waiting for a server to start.")

(defconstant +server-socket-poll-max-iterations+ 30
  "Maximum number of socket-existence probes (30 x 0.1 s = 3 s total wait).")

(defconstant +server-log-rotate-bytes+ (* 1024 1024)
  "Server log rotation threshold (§1.4 / R2.8): a log at or above this size is
   replaced with a fresh file at startup instead of appended to.")

(defun %server-log-if-output-exists-action (log-path)
  "The SB-EXT:RUN-PROGRAM :if-output-exists action for LOG-PATH: :supersede
   (start a fresh file) when the existing log is at least
   +server-log-rotate-bytes+, else :append."
  (handler-case
      (if (and (probe-file log-path)
               (>= (with-open-file (s log-path) (file-length s))
                   +server-log-rotate-bytes+))
          :supersede
          :append)
    (file-error () :append)
    (stream-error () :append)))

(defun %stale-socket-p (socket-path)
  "True when SOCKET-PATH exists but no server accepts connections on it.
   A leftover socket file like this (e.g. after a crash) should not block
   attaching: it is unlinked and a fresh server started instead of failing."
  (handler-case
      (and (probe-file socket-path)
           (not (handler-case
                    (let ((sock (nerimux/net:connect-to socket-path)))
                      (nerimux/net:close-socket sock)
                      t)
                  (sb-ext:timeout () nil)
                  (sb-bsd-sockets:socket-error () nil)
                  (file-error () nil)
                  (stream-error () nil))))
    (file-error () nil)
    (stream-error () nil)))

(defun %secure-log-directory (log-path)
  "Best-effort chmod LOG-PATH's parent directory to 0700 once it exists, so a
   server crash log holding SBCL backtraces (absolute paths, possibly
   pane/environment-derived data) is not left world/group-readable under
   whatever the process umask happens to be (CWE-732).

   SB-POSIX is an SBCL runtime module rather than an ASDF dependency, so this
   helper ensures it is loaded before the direct chmod call.

   Chmod is defense in depth for the log's contents, not a precondition for
   logging or for starting the server, so syscall failures are ignored."
  (require :sb-posix)
  (handler-case
      (sb-posix:chmod (directory-namestring log-path) #o700)
    (sb-posix:syscall-error () nil)))

(defun %launch-server-without-log (exe args)
  "Try the unredirected server launch after diagnostic logging is unavailable."
  (handler-case
      (sb-ext:run-program exe args :wait nil :output nil :error nil)
    (sb-ext:process-error () nil)
    (file-error () nil)
    (stream-error () nil)))

(defun %launch-server-and-poll-when-live (socket-path exe args log-path)
  "Spawn EXE/ARGS non-blocking, redirecting its stdout and stderr to LOG-PATH
   so a crash or runtime error in the auto-started headless server leaves a
   forensic trail instead of vanishing into /dev/null.  LOG-PATH's parent
   directory is created first since it lives under a per-server-name state
   directory that may not exist yet, and is chmod'd 0700 (%secure-log-directory)
   before the child can write into it.

   Crash-forensic logging is a purely diagnostic feature and must not become a
   hard dependency for starting a server: previously :output nil :error nil
   needed no directory at all, so a read-only or permission-denied
   XDG_STATE_HOME/NERIMUX_RUNTIME_STATE (common in containers/CI) would now
   fail server auto-start outright.  Creating/securing LOG-PATH's directory
   and the log-redirected run-program attempt are therefore wrapped together;
   known filesystem, stream, and process-launch failures fall back to an
   un-redirected launch instead of blocking startup."
  (let ((launched
          (handler-case
              (progn
                (ensure-directories-exist log-path)
                (%secure-log-directory log-path)
                (sb-ext:run-program exe args
                                    :wait nil
                                    :output log-path
                                    :if-output-exists
                                    (%server-log-if-output-exists-action log-path)
                                    :error :output))
            (file-error () (%launch-server-without-log exe args))
            (stream-error () (%launch-server-without-log exe args))
            (sb-ext:process-error () (%launch-server-without-log exe args)))))
    ;; Poll only when we actually attempted a launch.  This avoids the
    ;; unconditional 3-second dead-time when run-program silently failed.
    (when launched
      (loop repeat +server-socket-poll-max-iterations+
            until (probe-file socket-path)
            do (sleep +server-socket-poll-interval-seconds+)))))

(defun %server-respawn-command (session-name)
  "(values EXE ARGS) respawning this image as `… server SESSION-NAME`.
   sb-ext:*posix-argv* cannot be replayed for this: the C runtime strips the
   runtime options it consumed (--core, --noinform, …), so under the Nix
   wrapper — a bare sbcl runtime plus a separate core file — respawning
   argv[0] with only (\"server\" NAME) starts a plain SBCL REPL that never
   binds the socket.  Rebuild the command from *runtime-pathname* and
   *core-pathname* instead, and always suppress init files: the spawned
   server must stay as hermetic as the wrapper keeps its parent.  In an
   :executable-core image *core-pathname* equals the runtime and no --core
   option is needed; %application-argv (main-startup.lisp) strips the
   --no-userinit prefix either way."
  (let* ((runtime (namestring sb-ext:*runtime-pathname*))
         (core (and sb-ext:*core-pathname*
                    (namestring sb-ext:*core-pathname*))))
    (values runtime
            (append (when (and core (string/= core runtime))
                      (list "--noinform" "--core" core))
                    (list "--no-sysinit" "--no-userinit"
                          "server" session-name)))))

(defun %ensure-server-running (session-name)
  "Start a background server for SESSION-NAME if no live socket exists.
   A stale socket file (present but refusing connections) is unlinked
   first rather than treated as a live server (see %stale-socket-p).
   Uses sb-ext:run-program with %server-respawn-command's runtime+core
   command to spawn a separate process.
   Only enters the polling loop when run-program succeeded.
   Polls every +server-socket-poll-interval-seconds+ for up to
   +server-socket-poll-max-iterations+ iterations for the socket to appear.
   Signals an ERROR when the socket still does not exist afterward — the
   spawned server crashed, never started, or is simply slow — rather than
   returning silently as if it had succeeded (main's top-level handler-case
   turns this into a clean one-line message and exit 1, the same as any
   other startup error).
   The spawned server's stdout/stderr are redirected to %runtime-log-path's
   per-session-name log file so a crash leaves a forensic trail instead of
   being discarded."
  (multiple-value-bind (exe args) (%server-respawn-command session-name)
    (let ((socket-path (socket-path session-name))
          (log-path    (%runtime-log-path session-name)))
      (when (%stale-socket-p socket-path)
        (handler-case
            (delete-file socket-path)
          (file-error () nil)))
      (unless (probe-file socket-path)
        ;; Guard: run-program may fail in test environments or when the
        ;; binary is not yet on PATH.  Only poll if the spawn succeeded.
        ;; :wait nil means non-blocking, so run-program returns after starting the child.
        (%launch-server-and-poll-when-live socket-path exe args log-path))
      (unless (probe-file socket-path)
        (error "server failed to start (timed out waiting for socket at ~A)"
               socket-path)))))

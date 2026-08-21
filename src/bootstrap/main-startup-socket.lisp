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
  (if (and (probe-file log-path)
           (>= (or (ignore-errors
                     (with-open-file (s log-path) (file-length s)))
                   0)
               +server-log-rotate-bytes+))
      :supersede
      :append))

(defun %stale-socket-p (socket-path)
  "True when SOCKET-PATH exists but no server accepts connections on it.
   A leftover socket file like this (e.g. after a crash) should not block
   attaching: it is unlinked and a fresh server started instead of failing."
  (and (probe-file socket-path)
       (not (handler-case
                (let ((sock (nerimux/net:connect-to socket-path)))
                  (nerimux/net:close-socket sock)
                  t)
              (error () nil)))))

(defun %secure-log-directory (log-path)
  "Best-effort chmod LOG-PATH's parent directory to 0700 once it exists, so a
   server crash log holding SBCL backtraces (absolute paths, possibly
   pane/environment-derived data) is not left world/group-readable under
   whatever the process umask happens to be (CWE-732).

   Mirrors %socket-directory's sb-posix:chmod pattern in server.lisp exactly,
   including its dependency mechanism: sb-posix is not an ASDF dependency of
   this system (see nerimux/ports:find-posix-function's docstring), so it may
   not be loaded here.  %ensure-server-running -- this function's caller --
   runs in the ATTACHING/parent process spawning a new server child, not
   inside run-server itself, so run-server's own (require :sb-posix) cannot
   be assumed to have already executed in this process.  Hence the same
   (require :sb-posix) immediately before use that server.lisp performs.

   Chmod is defense in depth for the log's contents, not a precondition for
   logging or for starting the server, so any failure (missing sb-posix,
   permission error, race) is ignored exactly as %socket-directory ignores
   its own creation/chmod failures."
  (require :sb-posix)
  (ignore-errors
    (sb-posix:chmod (directory-namestring log-path) #o700)))

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
   any signal there falls back to an un-redirected launch instead of
   propagating and blocking startup -- diagnostics must not break the
   primary operation, so this degrades to no log rather than propagating."
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
            (condition ()
             (ignore-errors
               (sb-ext:run-program exe args :wait nil :output nil :error nil))))))
    ;; Poll only when we actually attempted a launch.  This avoids the
    ;; unconditional 3-second dead-time when run-program silently failed.
    (when launched
      (loop repeat +server-socket-poll-max-iterations+
            until (probe-file socket-path)
            do (sleep +server-socket-poll-interval-seconds+)))))

(defun %ensure-server-running (session-name)
  "Start a background server for SESSION-NAME if no live socket exists.
   A stale socket file (present but refusing connections) is unlinked
   first rather than treated as a live server (see %stale-socket-p).
   Uses sb-ext:run-program with *posix-argv* to spawn a separate process.
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
  (let* ((socket-path (socket-path session-name))
         (exe         (first sb-ext:*posix-argv*))
         (args        (list "server" session-name))
         (log-path    (%runtime-log-path session-name)))
    (when (%stale-socket-p socket-path)
      (ignore-errors (delete-file socket-path)))
    (unless (probe-file socket-path)
      ;; Guard: run-program may fail in test environments or when the
      ;; binary is not yet on PATH.  Only poll if the spawn succeeded.
      ;; :wait nil means non-blocking, so run-program returns after starting the child.
      (%launch-server-and-poll-when-live socket-path exe args log-path))
    (unless (probe-file socket-path)
      (error "server failed to start (timed out waiting for socket at ~A)"
             socket-path))))

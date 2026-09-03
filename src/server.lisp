(in-package #:nerimux)

(defun %socket-tmp-base ()
  "The socket base directory: $TMPDIR, else /tmp (§1.4 — no -L/-S override,
   and no legacy temp-dir env var override: R1.17 removed the CLI flags
   that could reach one, and R2.7 dropped the env var alongside them)."
  (let ((tmpdir (sb-ext:posix-getenv "TMPDIR")))
    (string-right-trim "/"
                       (if (and tmpdir (plusp (length tmpdir)))
                           tmpdir
                           "/tmp"))))

(defun %verify-socket-directory-private (dir uid)
  "Refuse to trust DIR as the socket boundary unless LSTAT shows it is,
   right now, a real directory (not a symlink), owned by UID, with mode
   exactly #o700.  Signals an error naming DIR and the failed property
   instead of returning when any check fails (fail-closed per the security
   model: docs/src/reference/security-model.md, \"The socket directory is
   the security boundary\").

   Uses LSTAT, never STAT: STAT follows a symlink and would report the
   permissions of whatever DIR points to rather than of DIR itself, which
   is exactly the check a symlinked DIR needs to fail."
  (let ((stat
         (handler-case (sb-posix:lstat dir)
           (sb-posix:syscall-error (c)
             (error
              "nerimux: refusing to start: cannot verify socket ~
                          directory ~A is private (~A)"
              dir
              c)))))
    (when (sb-posix:s-islnk (sb-posix:stat-mode stat))
      (error
       "nerimux: refusing to start: socket directory ~A is a ~
              symlink, not a real directory -- the socket boundary ~
              (docs/src/reference/security-model.md) cannot be trusted ~
              through a link another user may have created"
       dir))
    (unless (sb-posix:s-isdir (sb-posix:stat-mode stat))
      (error
       "nerimux: refusing to start: socket directory ~A is not a ~
              directory"
       dir))
    (unless (= (sb-posix:stat-uid stat) uid)
      (error
       "nerimux: refusing to start: socket directory ~A is owned by ~
              uid ~D, not the current uid ~D -- another user could control ~
              the socket boundary"
       dir
       (sb-posix:stat-uid stat)
       uid))
    (let ((mode (logand (sb-posix:stat-mode stat) #o777)))
      (unless (= mode #o700)
        (error
         "nerimux: refusing to start: socket directory ~A has mode ~
                ~3,'0O, not the required 0700 -- a group- or ~
                world-accessible directory would let another local user ~
                reach the socket"
         dir
         mode)))
    stat))

(defun %socket-directory ()
  "Per-UID socket directory <base>/nerimux-<uid>, created mode 0700 when
   possible and then VERIFIED (not merely attempted) to be private before
   being trusted: see docs/src/reference/security-model.md, \"The socket
   directory is the security boundary\" -- anyone who can reach the socket
   this directory holds can run commands as the owning user.  Returns the
   directory string without a trailing slash, or signals an error naming
   the path and the failed property (%verify-socket-directory-private,
   above) when the directory cannot be made private.  Startup refuses to
   proceed rather than warn-and-continue: a directory that already existed
   as a symlink, or already belonged to another uid, or was left
   group/world-writable, must stop the server, not just fail to fix itself.

   CHMOD is gated on having just created DIR, and never runs against a path
   that already existed.  SB-POSIX:CHMOD FOLLOWS SYMLINKS and exports no
   LCHMOD, so chmod-then-verify handed an attacker a confused deputy: plant
   nerimux-<uid> as a symlink to any directory the victim owns, and the
   victim's own startup would chmod THAT target to 0700 -- silently narrowing
   permissions on a directory of the attacker's choosing -- before the LSTAT
   below correctly refused to start.  Verifying first means a pre-existing
   path is only ever inspected, never mutated.

   Residual TOCTOU window: ENSURE-DIRECTORIES-EXIST and the LSTAT inside
   %VERIFY-SOCKET-DIRECTORY-PRIVATE both resolve DIR by path, so the race is
   narrowed -- to the gap between that LSTAT and the later socket BIND in
   RUN-SERVER -- rather than eliminated.  SB-POSIX binds no
   mkdirat/fchmodat/fstatat.  It does bind OPEN (with O-NOFOLLOW and
   O-DIRECTORY), FSTAT, FCHMOD and FCHDIR, which together could pin one
   descriptor across verify-and-bind; that is not done here because FCHDIR
   mutates process-wide working directory, and this server spawns PTY
   children from multiple threads that inherit it.  The obstacle is that
   cost, not the absence of a primitive."
  (require :sb-posix)
  (let* ((uid (sb-posix:getuid))
         (dir (format nil "~A/nerimux-~D" (%socket-tmp-base) uid))
         (pre-existing (handler-case (and (sb-posix:lstat dir) t)
                         (sb-posix:syscall-error () nil))))
    (unless pre-existing
      (handler-case
          (ensure-directories-exist (format nil "~A/" dir))
        (file-error () nil))
      (handler-case
          (sb-posix:chmod dir #o700)
        (sb-posix:syscall-error () nil)))
    (%verify-socket-directory-private dir uid)
    dir))

(defun socket-path (name)
  "Filesystem path of the Unix socket for the server named NAME: a fixed name
   inside the per-UID socket directory (§1.4). No -L/-S override exists —
   R1.17 removed the CLI flags that could set one."
  (format nil "~A/nerimux-~A.sock" (%socket-directory) name))

(defun %relayout-active-window (session rows cols)
  "Relayout SESSION's active window for ROWS and COLS, if any."
  (let ((active-window (session-active-window session)))
    (when active-window
      (window-relayout active-window (- rows +status-line-rows+) cols))))

(defun %start-session-reader-threads (session)
  (mapcar #'start-reader-thread (all-panes session)))

(defun %close-session-ptys (session)
  (dolist (pane (all-panes session))
    (close-pane-pty pane)))

(defun run-server (name)
  "Run a headless server owning a session, serving clients attaching to
   (socket-path NAME).  The session persists across detaches until its last
   window is killed."
  (require :sb-posix)
  (install-pty-port)
  (setf *running*          t
        *dirty*            t
        *resize-pending*   nil
        *server-sessions*  nil
        *runtime-server-name* name)
  (let* ((session (create-initial-session *term-rows* *term-cols*))
         (path    (socket-path name)))
    (setf *bound-socket-path* path)
    (server-add-session session)
    (handler-case (delete-file path)
      (file-error () nil))
    (let* ((listener (make-listener path))
           (reader-threads (%start-session-reader-threads session)))
        (install-sigwinch-handler)
        (unwind-protect
            (%run-multi-server-loop listener session)
          (stop-reader-threads reader-threads)
          (close-socket listener)
          (handler-case (delete-file path)
            (file-error () nil))
          (%close-session-ptys session)))))

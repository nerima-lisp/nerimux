(in-package #:nerimux/test)

;;;; socket-path and stale-socket tests

(describe "server-suite"

  ;;; -- socket-path naming ------------------------------------------------------

  ;; socket-path embeds the session name in the filename and always ends with .sock.
  (it "socket-path-properties-table"
    (dolist (row '(("mysess" "nerimux-mysess.sock" "session name embedded in path")
                   ("anysess" ".sock" "path always ends with .sock")))
      (destructuring-bind (sess expected desc) row
        (declare (ignore desc))
        (let ((path (nerimux::socket-path sess)))
          (expect (search expected path))))))

  ;; socket-path returns distinct paths for distinct session names.
  (it "socket-path-distinct-for-different-names"
    (let ((p1 (nerimux::socket-path "alpha"))
          (p2 (nerimux::socket-path "beta")))
      (expect (string/= p1 p2))))

  ;; socket-path embeds $TMPDIR in the result when it is set (§1.4 / R2.7):
  ;; no -L/-S override and no $TMUX_TMPDIR exist any more (R1.17 removed the
  ;; CLI flags, R2.7 dropped the env var alongside them), so $TMPDIR is the
  ;; only input to the socket base directory.
  (it "socket-path-uses-tmpdir-env-var"
    (with-temporary-posix-environment-variable ("TMPDIR" "/var/folders/test")
      (let ((path (nerimux::socket-path "envtest")))
        (expect (search "/var/folders/test" path)))))

  ;; socket-path uses /tmp as the socket directory when $TMPDIR is unset.
  (it "socket-path-falls-back-to-tmp-when-no-tmpdir"
    (with-temporary-posix-environment-variable ("TMPDIR" nil)
      (let ((path (nerimux::socket-path "tmptestfb")))
        (expect (search "/tmp" path)))))

  ;; Sockets live in a per-UID directory.
  (it "socket-path-uses-per-uid-directory"
    (let ((path (nerimux::socket-path "uidtest")))
      (expect (search (format nil "nerimux-~D/" (sb-posix:getuid)) path))))

  ;; The per-UID socket directory is created mode 0700 (§1.4 / R2.7), so a
  ;; socket file another local user could connect through is not left
  ;; reachable via a world/group-traversable directory.
  (it "socket-directory-is-mode-0700"
    (let ((dir (nerimux::%socket-directory)))
      (expect (= #o700 (logand (sb-posix:stat-mode (sb-posix:stat dir)) #o777)))))

  ;; socket-path uses a fixed name for a given session name — no -L/-S
  ;; override can change it (R1.17 removed both CLI flags).
  (it "socket-path-name-is-fixed-for-a-given-session-name"
    (let ((p1 (nerimux::socket-path "fixedname"))
          (p2 (nerimux::socket-path "fixedname")))
      (expect (string= p1 p2))
      (expect (search "nerimux-fixedname.sock" p1))))

  ;;; -- stale-socket ------------------------------------------------------------

  ;; %stale-socket-p returns T for an existing file that refuses connections.
  (it "stale-socket-p-detects-dead-socket-file"
    (expect (null (nerimux::%stale-socket-p "/nonexistent/nerimux-stale-probe.sock")))
    (let ((path (format nil "~A/nerimux-stale-test-~D.sock"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               (declare (ignore s)))
             (expect (eq t (and (nerimux::%stale-socket-p path) t))))
        (ignore-errors (delete-file path)))))

  ;; %stale-socket-p returns NIL when a live listener accepts on the path.
  (it "stale-socket-p-live-listener-is-not-stale"
    (let ((path (nerimux/net::%make-probe-socket-path)))
      (if (nerimux/net:unix-socket-available-p)
          (let ((listener (nerimux/net:make-listener path)))
            (unwind-protect
                 (expect (null (nerimux::%stale-socket-p path)))
              (nerimux/net:close-socket listener)
              (ignore-errors (delete-file path))))
          (expect t :to-be-truthy))))

  ;;; -- ensure-server-running -----------------------------------------------

  ;; %ensure-server-running signals an error when the launch-and-poll attempt
  ;; never produces a socket (a crashed or never-started background server),
  ;; rather than returning silently as if it had succeeded — a real user
  ;; would otherwise see `new-session -d` "succeed" with no server running.
  ;; A random, never-used session name stands in for "no server running":
  ;; there is no override left to force an unreachable path (R1.17 removed
  ;; -L/-S), so socket-path's real, fixed-name resolution is exercised as-is.
  (it "ensure-server-running-signals-when-socket-never-appears"
    (with-stubbed-fdefinition
        ((nerimux::%launch-server-and-poll-when-live
          (lambda (&rest args) (declare (ignore args)) nil)))
      (signals error
        (nerimux::%ensure-server-running
         (format nil "test-session-never-appears-~D" (random 1000000)))
        "must signal when the socket never appears after launch-and-poll")))

  ;;; -- launch-server-and-poll: diagnostics must not block startup --------------

  ;; %launch-server-and-poll-when-live redirects the spawned server's
  ;; stdout/stderr to a per-server-name log file for crash forensics, but that
  ;; is a purely diagnostic feature: it must not become a hard dependency for
  ;; starting a server.  When LOG-PATH's parent directory cannot be created
  ;; (e.g. a read-only or permission-denied XDG_STATE_HOME/
  ;; NERIMUX_RUNTIME_STATE -- common in containers/CI), the function must fall
  ;; back to an un-redirected run-program call rather than propagating and
  ;; blocking server auto-start, where previously :output nil :error nil
  ;; needed no directory at all.
  ;;
  ;; The unwritable-directory condition is forced with a real filesystem
  ;; hazard -- a plain file sitting where ENSURE-DIRECTORIES-EXIST needs to
  ;; create a directory -- rather than stubbing ENSURE-DIRECTORIES-EXIST
  ;; itself, since COMMON-LISP is a locked package.  SB-EXT:RUN-PROGRAM is
  ;; stubbed to capture the fallback call's arguments without spawning a real
  ;; process; SB-EXT is also locked, hence WITHOUT-PACKAGE-LOCKS, the same
  ;; idiom main-entry-tests.lisp already uses to stub SB-EXT:EXIT.
  (it "launch-server-falls-back-to-unredirected-run-program-when-log-directory-is-unwritable"
    (let* ((blocker (format nil "~A/nerimux-log-blocker-~D"
                            (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                            (random 1000000)))
           (log-path (merge-pathnames "sub/blocked.log" (format nil "~A/" blocker)))
           (calls nil))
      (unwind-protect
           (progn
             (with-open-file (s blocker :direction :output :if-does-not-exist :create)
               (declare (ignore s)))
             (sb-ext:without-package-locks
               (let ((orig (fdefinition 'sb-ext:run-program)))
                 (setf (fdefinition 'sb-ext:run-program)
                       (lambda (&rest args) (push args calls) nil))
                 (unwind-protect
                      (nerimux::%launch-server-and-poll-when-live
                       "/nonexistent-dir-xyz/never.sock" "nerimux" nil log-path)
                   (setf (fdefinition 'sb-ext:run-program) orig))))
             (expect (= 1 (length calls)))
             (destructuring-bind (exe-arg args-arg &rest keys) (first calls)
               (declare (ignore args-arg))
               (expect (string= "nerimux" exe-arg))
               (expect (eq nil (getf keys :wait :absent)))
               (expect (eq nil (getf keys :output :absent)))
               (expect (eq nil (getf keys :error :absent)))))
        (ignore-errors (delete-file blocker)))))

  ;; %secure-log-directory chmods the log's parent directory to 0700 so a
  ;; server crash log (which can hold SBCL backtraces: absolute paths,
  ;; possibly pane/environment-derived data) is not left world/group-readable
  ;; under whatever the process umask happens to be (CWE-732).  Mirrors
  ;; %socket-directory's sb-posix:chmod pattern in server.lisp.  Checked
  ;; against the real filesystem mode bits rather than stubbing
  ;; sb-posix:chmod, since the mode bits are the actual security property at
  ;; stake.
  (it "secure-log-directory-chmods-the-log-parent-directory-to-0700"
    (let* ((dir (format nil "~A/nerimux-log-secure-test-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000)))
           (log-path (merge-pathnames "probe.log" (format nil "~A/" dir))))
      (unwind-protect
           (progn
             (ensure-directories-exist log-path)
             (nerimux::%secure-log-directory log-path)
             (expect (= #o700
                        (logand (sb-posix:stat-mode (sb-posix:stat dir)) #o777))))
        (ignore-errors (sb-posix:rmdir dir)))))

  ;; End-to-end: %launch-server-and-poll-when-live itself must call
  ;; %secure-log-directory on its happy path (not only when called directly),
  ;; so the chmod actually happens for every real invocation, not just when
  ;; exercised in isolation.  sb-ext:run-program is stubbed to avoid spawning
  ;; a real process; the stub returns nil so the socket-polling loop is
  ;; skipped.
  (it "launch-server-secures-the-log-directory-on-the-happy-path"
    (let* ((dir (format nil "~A/nerimux-log-happy-test-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000)))
           (log-path (merge-pathnames "server.log" (format nil "~A/" dir))))
      (unwind-protect
           (progn
             (sb-ext:without-package-locks
               (let ((orig (fdefinition 'sb-ext:run-program)))
                 (setf (fdefinition 'sb-ext:run-program)
                       (lambda (&rest args) (declare (ignore args)) nil))
                 (unwind-protect
                      (nerimux::%launch-server-and-poll-when-live
                       "/nonexistent-dir-xyz/never.sock" "nerimux" nil log-path)
                   (setf (fdefinition 'sb-ext:run-program) orig))))
             (expect (= #o700
                        (logand (sb-posix:stat-mode (sb-posix:stat dir)) #o777))))
        (ignore-errors (sb-posix:rmdir dir)))))

  ;;; -- server log rotation (R2.8) ------------------------------------------

  ;; %server-log-if-output-exists-action returns :append when LOG-PATH does
  ;; not exist yet (first server start for this name), and when it exists but
  ;; is smaller than +server-log-rotate-bytes+.
  (it "server-log-if-output-exists-action-appends-when-small-or-absent"
    (expect (eq :append
                (nerimux::%server-log-if-output-exists-action
                 "/nonexistent-dir-xyz/never-created.log")))
    (let ((path (format nil "~A/nerimux-log-small-test-~D.log"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               (write-string "small log, well under the rotation threshold" s))
             (expect (eq :append (nerimux::%server-log-if-output-exists-action path))))
        (ignore-errors (delete-file path)))))

  ;; %server-log-if-output-exists-action returns :supersede — start a fresh
  ;; file — once LOG-PATH is at or above +server-log-rotate-bytes+ (1 MB,
  ;; §1.4 / R2.8), so a server that has been running a long time does not
  ;; grow its log file without bound.
  (it "server-log-if-output-exists-action-supersedes-past-1mb"
    (let ((path (format nil "~A/nerimux-log-big-test-~D.log"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               (write-sequence
                (make-string nerimux::+server-log-rotate-bytes+ :initial-element #\a)
                s))
             (expect (eq :supersede (nerimux::%server-log-if-output-exists-action path))))
        (ignore-errors (delete-file path))))))

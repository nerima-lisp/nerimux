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
    ;; %socket-directory now VERIFIES the per-uid directory (fail-closed),
    ;; so the fixture TMPDIR must be a real, writable location it can
    ;; actually create and secure -- a fixed path like /var/folders/test
    ;; that this sandbox cannot create previously worked only because the
    ;; old code ignored ENSURE-DIRECTORIES-EXIST/CHMOD failures outright.
    (let ((base (format nil "~A/nerimux-tmpdir-env-fixture-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (with-temporary-posix-environment-variable ("TMPDIR" base)
             (let ((path (nerimux::socket-path "envtest")))
               (expect (search base path))))
        (ignore-errors
         (sb-posix:rmdir (format nil "~A/nerimux-~D" base (sb-posix:getuid))))
        (ignore-errors (sb-posix:rmdir base)))))

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

  ;;; -- socket directory privacy: %verify-socket-directory-private (fail-closed) -
  ;;;
  ;;; %socket-directory used to attempt ENSURE-DIRECTORIES-EXIST and CHMOD
  ;;; #o700 and ignore either failing, trusting socket BIND to surface a
  ;;; permission problem later.  That covers BIND failing outright but not a
  ;;; pre-existing directory that is a symlink, owned by another uid, or left
  ;;; group/world-writable -- none of which stop BIND from succeeding.  These
  ;;; cases now go through %verify-socket-directory-private, which signals an
  ;;; error (refusing startup) rather than warning and continuing.  Fixture
  ;;; directories are built under a fresh, uniquely-named scratch path and
  ;;; removed afterward; none of these depend on $TMPDIR/nerimux-<uid> or its
  ;;; real mode.

  ;; An acceptable directory (real directory, owned by us, mode exactly
  ;; 0700) passes: no error, and the STAT it returns is truthy.
  (it "verify-socket-directory-private-accepts-a-private-directory"
    (let ((dir (format nil "~A/nerimux-privacy-ok-~D"
                       (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                       (random 1000000))))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/" dir))
             (sb-posix:chmod dir #o700)
             (expect (and (nerimux::%verify-socket-directory-private dir (sb-posix:getuid)) t)
                     :to-be-truthy))
        (ignore-errors (sb-posix:rmdir dir)))))

  ;; A directory whose mode is not exactly 0700 (here 0755, group- and
  ;; world-readable/executable) is rejected: this is the "left
  ;; group/world-writable" case the security model calls the whole trust
  ;; boundary.
  (it "verify-socket-directory-private-rejects-non-0700-mode"
    (let ((dir (format nil "~A/nerimux-privacy-mode-~D"
                       (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                       (random 1000000))))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/" dir))
             (sb-posix:chmod dir #o755)
             (signals error
               (nerimux::%verify-socket-directory-private dir (sb-posix:getuid))
               "must refuse a group/world-accessible socket directory"))
        (ignore-errors (sb-posix:rmdir dir)))))

  ;; A symlinked directory is rejected via LSTAT on the link itself, even
  ;; though the link's target is a real, privately-owned, mode-0700
  ;; directory -- STAT (which follows the link) would incorrectly approve
  ;; this; LSTAT is what makes the check see the symlink.
  (it "verify-socket-directory-private-rejects-a-symlink"
    (let* ((target (format nil "~A/nerimux-privacy-target-~D"
                           (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                           (random 1000000)))
           (link (format nil "~A/nerimux-privacy-link-~D"
                         (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                         (random 1000000))))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/" target))
             (sb-posix:chmod target #o700)
             (sb-posix:symlink target link)
             (signals error
               (nerimux::%verify-socket-directory-private link (sb-posix:getuid))
               "must refuse a symlinked socket directory even when its target is private"))
        (ignore-errors (sb-posix:unlink link))
        (ignore-errors (sb-posix:rmdir target)))))

  ;; A path that is a regular file, not a directory, is rejected.
  (it "verify-socket-directory-private-rejects-a-non-directory"
    (let ((path (format nil "~A/nerimux-privacy-file-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               (declare (ignore s)))
             (signals error
               (nerimux::%verify-socket-directory-private path (sb-posix:getuid))
               "must refuse a socket directory path that is a plain file"))
        (ignore-errors (delete-file path)))))

  ;; A path that does not exist at all is rejected (LSTAT fails) rather than
  ;; silently treated as acceptable.
  (it "verify-socket-directory-private-rejects-a-missing-path"
    (signals error
      (nerimux::%verify-socket-directory-private
       (format nil "/nonexistent-nerimux-privacy-dir-~D" (random 1000000))
       (sb-posix:getuid))
      "must refuse when the socket directory does not exist"))

  ;; Ownership mismatch is rejected.  Chowning a real fixture to another uid
  ;; would require privileges this test cannot assume, so the mismatch is
  ;; expressed the portable way: the directory is genuinely owned by the
  ;; current uid, and EXPECTED-UID is deliberately wrong, which exercises
  ;; exactly the same STAT-UID/=UID comparison a real cross-uid directory
  ;; would fail.
  (it "verify-socket-directory-private-rejects-uid-mismatch"
    (let ((dir (format nil "~A/nerimux-privacy-uid-~D"
                       (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                       (random 1000000))))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/" dir))
             (sb-posix:chmod dir #o700)
             (signals error
               (nerimux::%verify-socket-directory-private
                dir (1+ (sb-posix:getuid)))
               "must refuse when the directory's owner does not match the expected uid"))
        (ignore-errors (sb-posix:rmdir dir)))))

  ;; End-to-end: %socket-directory itself refuses to start when
  ;; $TMPDIR/nerimux-<uid> already exists as a symlink -- the exact defect
  ;; this change closes.  ENSURE-DIRECTORIES-EXIST and CHMOD both resolve
  ;; the symlinked path (CHMOD follows it, privately securing the target,
  ;; not the link), so only the LSTAT-based verification catches this.
  (it "socket-directory-refuses-a-pre-existing-symlinked-directory"
    (let* ((base (format nil "~A/nerimux-privacy-base-~D"
                         (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                         (random 1000000)))
           (target (format nil "~A/real-target" base))
           (uid-dir (format nil "~A/nerimux-~D" base (sb-posix:getuid))))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/" target))
             (sb-posix:chmod target #o700)
             (sb-posix:symlink target uid-dir)
             (with-temporary-posix-environment-variable ("TMPDIR" base)
               (signals error
                 (nerimux::%socket-directory)
                 "must refuse to start when the per-uid socket directory is a pre-existing symlink")))
        (ignore-errors (sb-posix:unlink uid-dir))
        (ignore-errors (sb-posix:rmdir target))
        (ignore-errors (sb-posix:rmdir base)))))

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

(in-package #:nerimux/test)

(describe "server-suite"


  (it "socket-path-properties-table"
    (dolist (row '(("mysess" "nerimux-mysess.sock" "session name embedded in path")
                   ("anysess" ".sock" "path always ends with .sock")))
      (destructuring-bind (sess expected desc) row
        (declare (ignore desc))
        (let ((path (nerimux::socket-path sess)))
          (expect (search expected path))))))

  (it "socket-path-distinct-for-different-names"
    (let ((p1 (nerimux::socket-path "alpha"))
          (p2 (nerimux::socket-path "beta")))
      (expect (string/= p1 p2))))

  (it "socket-path-uses-tmpdir-env-var"
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

  (it "socket-path-falls-back-to-tmp-when-no-tmpdir"
    (with-temporary-posix-environment-variable ("TMPDIR" nil)
      (let ((path (nerimux::socket-path "tmptestfb")))
        (expect (search "/tmp" path)))))

  (it "socket-tmp-base-falls-back-when-tmpdir-is-empty"
    (with-temporary-posix-environment-variable ("TMPDIR" "")
      (expect (string= "/tmp" (nerimux::%socket-tmp-base)))))

  (it "relayout-active-window-adjusts-for-the-status-row"
    (let ((session (make-fake-session))
          (calls nil))
      (with-stubbed-fdefinition
          ((nerimux::window-relayout
             (lambda (window rows cols)
               (push (list window rows cols) calls))))
        (nerimux::%relayout-active-window session 40 120)
        (destructuring-bind (window rows cols) (first calls)
          (expect (eq (session-active-window session) window))
          (expect (= 39 rows))
          (expect (= 120 cols))))))

  (it "relayout-active-window-does-nothing-without-a-window"
    (let ((calls nil))
      (with-empty-session (session)
        (with-stubbed-fdefinition
            ((nerimux::window-relayout
               (lambda (&rest args) (push args calls))))
          (nerimux::%relayout-active-window session 40 120)
          (expect (null calls))))))

  (it "socket-path-uses-per-uid-directory"
    (let ((path (nerimux::socket-path "uidtest")))
      (expect (search (format nil "nerimux-~D/" (sb-posix:getuid)) path))))

  (it "socket-directory-is-mode-0700"
    (let ((dir (nerimux::%socket-directory)))
      (expect (= #o700 (logand (sb-posix:stat-mode (sb-posix:stat dir)) #o777)))))


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

  (it "verify-socket-directory-private-rejects-a-non-directory"
    (let ((path (format nil "~A/nerimux-privacy-file-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               nil)
             (signals error
               (nerimux::%verify-socket-directory-private path (sb-posix:getuid))
               "must refuse a socket directory path that is a plain file"))
        (ignore-errors (delete-file path)))))

  (it "verify-socket-directory-private-rejects-a-missing-path"
    (signals error
      (nerimux::%verify-socket-directory-private
       (format nil "/nonexistent-nerimux-privacy-dir-~D" (random 1000000))
       (sb-posix:getuid))
      "must refuse when the socket directory does not exist"))

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

  (it "socket-directory-recovers-when-the-initial-lstat-races-with-creation"
    (let ((first-probe t)
          (original-lstat (fdefinition 'sb-posix:lstat)))
      (with-stubbed-locked-fdefinitions
          ((sb-posix:lstat
             (lambda (path)
               (if (shiftf first-probe nil)
                   (error 'sb-posix:syscall-error)
                   (funcall original-lstat path)))))
        (let ((dir (nerimux::%socket-directory)))
          (expect (directory (format nil "~A/" dir)))))))

  (it "socket-directory-continues-after-creation-errors-before-verification"
    (with-stubbed-locked-fdefinitions
        ((sb-posix:lstat (lambda (path)
                           (declare (ignore path))
                           (error 'sb-posix:syscall-error :errno 2)))
         (ensure-directories-exist (lambda (path)
                                     (declare (ignore path))
                                     (error 'file-error)))
         (sb-posix:chmod (lambda (path mode)
                           (declare (ignore path mode))
                           (error 'sb-posix:syscall-error :errno 2))))
      (signals error
        (nerimux::%socket-directory))))

  (it "socket-path-name-is-fixed-for-a-given-session-name"
    (let ((p1 (nerimux::socket-path "fixedname"))
          (p2 (nerimux::socket-path "fixedname")))
      (expect (string= p1 p2))
      (expect (search "nerimux-fixedname.sock" p1))))

  (it "server-respawn-command-is-hermetic-and-session-specific"
    (multiple-value-bind (exe args)
        (nerimux::%server-respawn-command "session-name")
      (expect (string= (namestring sb-ext:*runtime-pathname*) exe))
      (expect (member "--no-sysinit" args :test #'string=))
      (expect (member "--no-userinit" args :test #'string=))
      (expect (equal "server" (nth (- (length args) 2) args)))
      (expect (equal "session-name" (car (last args))))))


  (it "stale-socket-p-detects-dead-socket-file"
    (expect (null (nerimux::%stale-socket-p "/nonexistent/nerimux-stale-probe.sock")))
    (let ((path (format nil "~A/nerimux-stale-test-~D.sock"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               nil)
             (expect (eq t (and (nerimux::%stale-socket-p path) t))))
        (ignore-errors (delete-file path)))))

  (it "stale-socket-p-treats-probe-file-errors-as-not-stale"
    (with-stubbed-locked-fdefinitions
        ((probe-file
          (lambda (path)
            (declare (ignore path))
            (error 'file-error))))
      (expect (null (nerimux::%stale-socket-p "/synthetic/socket")))))

  (it "stale-socket-p-live-listener-is-not-stale"
    (let ((path (nerimux/net::%make-probe-socket-path)))
      (if (nerimux/net:unix-socket-available-p)
          (let ((listener (nerimux/net:make-listener path)))
            (unwind-protect
                 (expect (null (nerimux::%stale-socket-p path)))
              (nerimux/net:close-socket listener)
              (ignore-errors (delete-file path))))
          (expect t :to-be-truthy))))


  (it "ensure-server-running-signals-when-socket-never-appears"
    (with-stubbed-fdefinition
        ((nerimux::%launch-server-and-poll-when-live
          (lambda (&rest args) (declare (ignore args)) nil)))
      (signals error
        (nerimux::%ensure-server-running
         (format nil "test-session-never-appears-~D" (random 1000000)))
        "must signal when the socket never appears after launch-and-poll")))

  (it "ensure-server-running-prints-a-starting-server-notice-before-spawning"
    (with-stubbed-fdefinition
        ((nerimux::%launch-server-and-poll-when-live
          (lambda (&rest args) (declare (ignore args)) nil)))
      (let (errout)
        (setf errout
              (with-output-to-string (*error-output*)
                (ignore-errors
                 (nerimux::%ensure-server-running
                  (format nil "test-session-notice-~D" (random 1000000))))))
        (expect (search "nerimux: starting server..." errout) :to-be-truthy))))

  (it "ensure-server-running-skips-spawn-for-a-live-socket"
    (let ((path (format nil "/tmp/nerimux-live-~D.sock" (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (stream path :direction :output :if-exists :supersede)
               (declare (ignore stream)))
             (with-stubbed-locked-fdefinitions
                 ((nerimux::socket-path (lambda (name)
                                          (declare (ignore name))
                                          path))
                  (nerimux::%stale-socket-p (lambda (socket)
                                              (declare (ignore socket))
                                              nil))
         (nerimux::%launch-server-and-poll-when-live
          (lambda (&rest args)
            (declare (ignore args))
            (error "live server must not be spawned"))))
               (finishes (nerimux::%ensure-server-running "already-running"))))
        (ignore-errors (delete-file path)))))

  (it "ensure-server-running-removes-a-stale-socket-before-spawning"
    (let ((deleted nil)
          (spawned nil)
          (original-delete-file (fdefinition 'delete-file)))
      (let ((path (format nil "/tmp/nerimux-stale-~D.sock" (random 1000000))))
        (unwind-protect
             (progn
               (with-open-file (stream path :direction :output :if-exists :supersede)
                 (declare (ignore stream)))
               (with-stubbed-locked-fdefinitions
          ((nerimux::socket-path (lambda (name)
                                   (declare (ignore name))
                                   path))
           (nerimux::%stale-socket-p (lambda (path)
                                       (declare (ignore path))
                                       t))
           (delete-file (lambda (path)
                          (setf deleted t)
                          (funcall original-delete-file path)))
           (nerimux::%launch-server-and-poll-when-live
            (lambda (&rest args)
              (declare (ignore args))
              (setf spawned t)
              (with-open-file (stream path :direction :output :if-exists :supersede)
                (declare (ignore stream))))))
                 (finishes (nerimux::%ensure-server-running "stale-session")))
               (expect deleted :to-be-truthy)
               (expect spawned :to-be-truthy))
          (ignore-errors (delete-file path))))))

  (it "ensure-server-running-continues-when-stale-socket-cannot-be-deleted"
    (with-stubbed-locked-fdefinitions
        ((probe-file (lambda (path)
                       (declare (ignore path))
                       t))
         (nerimux/net:connect-to (lambda (path)
                                   (declare (ignore path))
                                   (error 'sb-bsd-sockets:socket-error)))
         (delete-file (lambda (path)
                        (error 'file-error :pathname path)))
         (nerimux::%launch-server-and-poll-when-live
          (lambda (&rest args) (declare (ignore args)) nil)))
      (signals error
        (nerimux::%ensure-server-running "stale-socket-delete-failure"))))


  (it "launch-server-falls-back-to-unredirected-run-program-when-log-directory-is-unwritable"
    (let* ((blocker (format nil "~A/nerimux-log-blocker-~D"
                            (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                            (random 1000000)))
           (log-path (merge-pathnames "sub/blocked.log" (format nil "~A/" blocker)))
           (calls nil))
      (unwind-protect
           (progn
             (with-open-file (s blocker :direction :output :if-does-not-exist :create)
               nil)
             (with-stubbed-locked-fdefinitions
                 ((sb-ext:run-program
                    (lambda (&rest args) (push args calls) nil)))
               (nerimux::%launch-server-and-poll-when-live
                "/nonexistent-dir-xyz/never.sock" "nerimux" nil log-path))
             (expect (= 1 (length calls)))
             (destructuring-bind (exe-arg args-arg &rest keys) (first calls)
               (declare (ignore args-arg))
               (expect (string= "nerimux" exe-arg))
               (expect (eq nil (getf keys :wait :absent)))
               (expect (eq nil (getf keys :output :absent)))
               (expect (eq nil (getf keys :error :absent)))))
        (ignore-errors (delete-file blocker)))))

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

  (it "secure-log-directory-contains-chmod-syscall-errors"
    (sb-ext:without-package-locks
      (let ((original-chmod (fdefinition 'sb-posix:chmod)))
        (unwind-protect
             (progn
               (setf (fdefinition 'sb-posix:chmod)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error 'sb-posix:syscall-error)))
               (finishes (nerimux::%secure-log-directory "/synthetic/log")))
          (setf (fdefinition 'sb-posix:chmod) original-chmod)))))

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

  (it "launch-server-polls-after-a-successful-background-launch"
    (let* ((dir (format nil "~A/nerimux-log-poll-test-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000)))
           (log-path (merge-pathnames "server.log" (format nil "~A/" dir)))
           (probes 0))
      (unwind-protect
           (with-stubbed-locked-fdefinitions
               ((sb-ext:run-program
                  (lambda (&rest args)
                    (declare (ignore args))
                    t)))
             (with-stubbed-fdefinition
                 ((probe-file
                    (lambda (path)
                      (declare (ignore path))
                      (incf probes)
                      (and (> probes 1) t))))
               (nerimux::%launch-server-and-poll-when-live
                "/synthetic/socket" "nerimux" nil log-path)
               (expect (<= 2 probes))))
        (ignore-errors (sb-posix:rmdir dir)))))

  (it "launch-server-without-log-contains-generic-launch-failure"
    (sb-ext:without-package-locks
      (let ((orig (fdefinition 'sb-ext:run-program)))
        (unwind-protect
             (progn
               (setf (fdefinition 'sb-ext:run-program)
                     (lambda (&rest args)
                       (declare (ignore args))
                       (error "launch probe")))
               (finishes (nerimux::%launch-server-without-log
                          "nerimux" nil)))
          (setf (fdefinition 'sb-ext:run-program) orig)))))

  (it "launch-server-without-log-contains-io-failures"
    (dolist (condition-type '(file-error stream-error))
      (sb-ext:without-package-locks
        (let ((orig (fdefinition 'sb-ext:run-program)))
          (unwind-protect
               (progn
                 (setf (fdefinition 'sb-ext:run-program)
                       (lambda (&rest args)
                         (declare (ignore args))
                         (error condition-type)))
                 (finishes (nerimux::%launch-server-without-log
                            "nerimux" nil)))
            (setf (fdefinition 'sb-ext:run-program) orig))))))

  (it "launch-server-falls-back-after-redirected-stream-error"
    (sb-ext:without-package-locks
      (let* ((original-run-program (fdefinition 'sb-ext:run-program))
             (calls 0)
             (dir (format nil "~A/nerimux-log-stream-test-~D"
                          (string-right-trim "/"
                                             (or (sb-ext:posix-getenv "TMPDIR")
                                                 "/tmp"))
                          (random 1000000)))
             (log-path (merge-pathnames "server.log" (format nil "~A/" dir))))
        (unwind-protect
             (progn
               (ensure-directories-exist log-path)
               (setf (fdefinition 'sb-ext:run-program)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (incf calls)
                       (if (= calls 1)
                           (error 'stream-error)
                           t)))
               (finishes
                 (nerimux::%launch-server-and-poll-when-live
                  "/synthetic/socket" "nerimux" nil log-path))
               (expect (= 2 calls)))
          (setf (fdefinition 'sb-ext:run-program) original-run-program)
          (ignore-errors (sb-posix:rmdir dir))))))


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
        (ignore-errors (delete-file path)))))

  (it "server-log-if-output-exists-action-appends-when-log-is-not-readable"
    (let ((path (format nil "~A/nerimux-log-directory-probe-~D"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/child" path))
             (expect (eq :append
                         (nerimux::%server-log-if-output-exists-action path))))
        (ignore-errors (sb-posix:rmdir path)))))

  (it "server-log-if-output-exists-action-appends-after-probe-file-error"
    (sb-ext:without-package-locks
      (let ((original-probe-file (fdefinition 'probe-file)))
        (unwind-protect
             (progn
               (setf (fdefinition 'probe-file)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error 'file-error)))
               (expect (eq :append
          (nerimux::%server-log-if-output-exists-action
                            "/synthetic/log-path"))))
          (setf (fdefinition 'probe-file) original-probe-file)))))

  (it "server-log-if-output-exists-action-appends-after-stream-error"
    (sb-ext:without-package-locks
      (let ((original-probe-file (fdefinition 'probe-file)))
        (unwind-protect
             (progn
               (setf (fdefinition 'probe-file)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error 'stream-error)))
               (expect (eq :append
                           (nerimux::%server-log-if-output-exists-action
                            "/synthetic/log-path"))))
          (setf (fdefinition 'probe-file) original-probe-file)))))

  (it "stale-socket-p-returns-nil-after-probe-file-error"
    (sb-ext:without-package-locks
      (let ((original-probe-file (fdefinition 'probe-file)))
        (unwind-protect
             (progn
               (setf (fdefinition 'probe-file)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error 'file-error)))
               (expect (null (nerimux::%stale-socket-p "/synthetic/socket"))))
          (setf (fdefinition 'probe-file) original-probe-file)))))

  (it "stale-socket-p-treats-connection-file-errors-as-not-stale"
    (with-stubbed-locked-fdefinitions
        ((probe-file (lambda (path)
                       (declare (ignore path))
                       t))
         (nerimux/net:connect-to (lambda (path)
                                   (declare (ignore path))
                                   (error 'file-error))))
      (expect (null (nerimux::%stale-socket-p "/synthetic/socket")))))

  (it "stale-socket-p-treats-connection-stream-errors-as-not-stale"
    (with-stubbed-locked-fdefinitions
        ((probe-file (lambda (path)
                       (declare (ignore path))
                       t))
         (nerimux/net:connect-to (lambda (path)
                                   (declare (ignore path))
                                   (error 'stream-error))))
      (expect (null (nerimux::%stale-socket-p "/synthetic/socket")))))

  (it "stale-socket-p-treats-connection-timeouts-as-not-stale"
    (with-stubbed-locked-fdefinitions
        ((probe-file (lambda (path)
                       (declare (ignore path))
                       t))
         (nerimux/net:connect-to (lambda (path)
                                   (declare (ignore path))
                                   (error 'sb-ext:timeout))))
      (expect (null (nerimux::%stale-socket-p "/synthetic/socket")))))

  (it "stale-socket-p-returns-nil-after-probe-stream-error"
    (sb-ext:without-package-locks
      (let ((original-probe-file (fdefinition 'probe-file)))
        (unwind-protect
             (progn
               (setf (fdefinition 'probe-file)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error 'stream-error)))
               (expect (null (nerimux::%stale-socket-p "/synthetic/socket"))))
          (setf (fdefinition 'probe-file) original-probe-file)))))
  )

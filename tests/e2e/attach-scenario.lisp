(%configure-asdf-registry *e2e-repo-root*)

(asdf:load-system :nerimux)

(use-package :nerimux/pty)

(defconstant +e2e-startup-timeout-seconds+
  8
  "Maximum seconds to wait for nerimux and its inner shell to initialize before typing.")

(defconstant +e2e-startup-quiet-seconds+
  0.5
  "Seconds of quiet PTY output after first render before typing the marker command.")

(defconstant +e2e-marker-timeout-seconds+
  6
  "Maximum seconds to wait for the marker to appear in the rendered output.")

(defconstant +e2e-detach-timeout-seconds+
  3
  "Maximum seconds to wait for nerimux to exit after the detach key.")

(defconstant +e2e-exit-wait-poll-millis+
  200
  "Per-iteration PTY-CHILD-EXIT-STATUS timeout inside
   %WAIT-FOR-CHILD-EXIT-DRAINING, in milliseconds (CL-DATE-KIT:DURATION-OF-
   SECONDS only accepts an integer, so a sub-second poll interval needs the
   millisecond constructor instead). Short so the loop keeps returning to
   drain the PTY between exit-status checks, rather than parking in one
   long PROCESS-WAIT the way the bare call used to.")

(defconstant +e2e-poll-timeout-us+
  nerimux/ports:+poll-timeout-us+
  "Select timeout in microseconds when polling the PTY for output.")

(defconstant +e2e-read-buf-size+
  nerimux/ports:+pty-buf-size+
  "PTY read buffer size in bytes.")

(defconstant +e2e-search-window-bytes+
  (* 64 1024)
  "Maximum recent PTY output bytes to scan for the marker.")

(defun %run-git (&rest args)
  (multiple-value-bind (exit-code stdout stderr timed-out)
      (run-program-bounded "git" args :timeout-seconds 20 :search t)
    (unless (and (eql exit-code 0) (not timed-out))
      (error "git ~{~A~^ ~} failed: exit=~S timeout=~S stderr=~S"
             args exit-code timed-out stderr))
    stdout))

(defun %prepare-bare-worktree ()
  "Create a real bare repository with one linked worktree for attach E2E."
  (let* ((tmpdir (uiop:ensure-directory-pathname
                  (or (sb-ext:posix-getenv "TMPDIR") "/tmp/")))
         (root (merge-pathnames "git-attach/" tmpdir))
         (seed (merge-pathnames "seed/" root))
         (bare (merge-pathnames "repository.git/" root))
         (worktree (merge-pathnames "worktree/" root))
         (readme (merge-pathnames "README" seed)))
    (ensure-directories-exist root)
    (%run-git "init" "-q" (namestring seed))
    (with-open-file (stream readme :direction :output :if-exists :supersede
                                   :if-does-not-exist :create)
      (write-line "nerimux E2E" stream))
    (%run-git "-C" (namestring seed) "config" "user.email"
              "nerimux-e2e@example.invalid")
    (%run-git "-C" (namestring seed) "config" "user.name" "nerimux E2E")
    (%run-git "-C" (namestring seed) "add" "README")
    (%run-git "-C" (namestring seed) "commit" "-q" "-m" "initial")
    (%run-git "clone" "--bare" "-q" (namestring seed) (namestring bare))
    (%run-git "--git-dir" (namestring bare) "worktree" "add" "--detach"
              "-q" (namestring worktree) "HEAD")
    (let ((worktree-list
            (%run-git "--git-dir" (namestring bare) "worktree" "list"
                      "--porcelain")))
      (let ((expected (string-right-trim "/"
                                         (namestring (truename worktree)))))
        (unless (search expected worktree-list)
          (error "git worktree list omitted linked worktree ~A" worktree)))
    (namestring worktree))))

(defun %wait-for-marker (fd substr seconds acc)
  "Poll FD for PTY output up to SECONDS, accumulating into ACC.
   Returns T when SUBSTR appears in the output, NIL on timeout."
  (let ((deadline
         (+ (get-internal-real-time) (* seconds internal-time-units-per-second)))
        (mlen (length substr)))
    (loop (when (> (get-internal-real-time) deadline)
            (return nil)) (when (select-fds (list fd) +e2e-poll-timeout-us+)
                            (let ((chunk
                                   (pty-read-blocking-into fd
                                                           (make-array
                                                            +e2e-read-buf-size+
                                                            :element-type
                                                            '(unsigned-byte 8)))))
                              (when chunk
                                (%accumulate-chunk acc chunk)
                                (when 
                                    (%search-in-tail substr
                                                     acc
                                                     (max
                                                      +e2e-search-window-bytes+
                                                      mlen))
                                  (return t))))))))

(defun %wait-for-startup-render (fd seconds acc)
  "Poll FD until nerimux has rendered at least once and output has gone quiet.
   The integration smoke drives the built binary, whose startup time varies
   enough that a fixed sleep can type before raw mode and the first pane are ready."
  (let ((deadline
         (+ (get-internal-real-time) (* seconds internal-time-units-per-second)))
        (quiet-ticks
         (* +e2e-startup-quiet-seconds+ internal-time-units-per-second))
        (last-output nil))
    (loop (let ((now (get-internal-real-time)))
            (when (> now deadline)
              (return (not (null last-output))))
            (when (and last-output (>= (- now last-output) quiet-ticks))
              (return t))) (when (select-fds (list fd) +e2e-poll-timeout-us+)
                             (let ((chunk
                                    (pty-read-blocking-into fd
                                                            (make-array
                                                             +e2e-read-buf-size+
                                                             :element-type
                                                             '(unsigned-byte 8)))))
                               (when chunk
                                 (%accumulate-chunk acc chunk)
                                 (setf last-output (get-internal-real-time))))))))

(defun %wait-for-child-exit-draining (fd seconds acc)
  "Poll FD for up to SECONDS, draining any output into ACC, while
   repeatedly checking for the child's exit status. Returns (VALUES
   exit-code exit-kind), the same shape PTY-CHILD-EXIT-STATUS returns, or
   (VALUES NIL NIL) on timeout.

   A detaching client can still be mid-teardown (alt-screen exit, cursor
   restore, status line) when the detach key is sent. A bare, undrained
   PTY-CHILD-EXIT-STATUS call here previously deadlocked: nothing read the
   PTY after detach, so that teardown output filled the kernel PTY buffer
   and the child blocked forever inside its own WRITE(2), which
   PTY-CHILD-EXIT-STATUS's PROCESS-WAIT can never observe an exit from.
   Confirmed live via `sample` on the stuck child: 100% of samples showed
   its main thread parked in WRITE. Keeping the drain going here, alongside
   the exit check, lets that write complete."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (when (> (get-internal-real-time) deadline) (return (values nil nil)))
      (when (select-fds (list fd) +e2e-poll-timeout-us+)
        (let ((chunk (pty-read-blocking-into fd (make-array +e2e-read-buf-size+ :element-type '(unsigned-byte 8)))))
          (when chunk (%accumulate-chunk acc chunk))))
      (multiple-value-bind (exit-code exit-kind)
          (pty-child-exit-status
           fd (cl-date-kit:duration-of-millis +e2e-exit-wait-poll-millis+))
        (when exit-kind
          (return (values exit-code exit-kind)))))))

(defun run-attach-scenario (binary)
  "Drive BINARY through `attach` from a linked worktree, type a Git marker,
   then detach. Returns
   (VALUES pass-p detail-string); never calls SB-EXT:EXIT, so the caller
   supplies the process exit status."
  (format t "~&[e2e] driving ~A~%" binary)
  (let* ((worktree (handler-case (%prepare-bare-worktree)
                     (error (condition)
                       (error "bare worktree setup failed: ~A" condition))))
         (marker "E2E_GIT_WORKTREE_true")
         (command
           (format nil
                   "printf 'E2E_GIT_WORKTREE_%s\\n' \"$(git rev-parse --is-inside-work-tree)\"~%")))
    (multiple-value-bind (fd pid)
        (forkpty-with-shell 24 80
                            :start-dir worktree
                            :default-command (format nil "exec ~S attach" binary)
                            :environment (sb-ext:posix-environ))
    (unwind-protect
         (let ((startup-acc (%make-accumulator))
               (acc (%make-accumulator)))
           (assert (null (search marker command)))
           (%wait-for-startup-render fd +e2e-startup-timeout-seconds+ startup-acc)
           (pty-write fd command)
           (let ((found (%wait-for-marker fd marker +e2e-marker-timeout-seconds+ acc)))
             (pty-write fd (make-array 2 :element-type '(unsigned-byte 8)
                                          :initial-contents (list 17 (char-code #\d))))
             (multiple-value-bind (exit-code exit-kind)
                 (%wait-for-child-exit-draining fd +e2e-detach-timeout-seconds+ acc)
               (if (and found (eq :exited exit-kind) (zerop exit-code))
                   (values t "linked worktree Git marker rendered and nerimux exited cleanly")
                   (values nil
                           (format nil "marker=~A exit-kind=~A exit-code=~A captured=~D bytes"
                                   (if found :found :missing) exit-kind exit-code
                                   (fill-pointer acc)))))))
      (pty-close fd pid)))))

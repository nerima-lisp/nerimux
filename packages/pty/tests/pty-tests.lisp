(in-package #:nerimux/test/pty)

;;;; Unit tests for pty.lisp: argument-assembly helpers, and sandbox-safe
;;;; guard/round-trip behaviour that needs no real PTY.
;;;;
;;;; R9.2 of docs/notes/workspace-requirements.md split this file: every case
;;;; that actually spawned a real PTY (directly via forkpty-with-shell, or
;;;; through WITH-PTY-SHELL) moved to tests/pty/pty-unit-tests.lisp, in the new
;;;; nerimux/pty-test ASDF system, which `nix flake check` does not run.  The
;;;; cases below assert on pure arguments/constants, an fboundp reachability
;;;; check, or a pipe-fd round-trip (with-pipe-fds) -- none of which need
;;;; /dev/ptmx -- so they stayed here.
;;;;
;;;; (The child-environment assignment logic now lives in
;;;; session-environment-tests.lisp.)

(defun %wait-until-process-gone (pid &optional (deadline-seconds 5))
  "Poll until PID is no longer a live process, bounded by DEADLINE-SECONDS.
   Returns T when it went away, NIL when the deadline passed first.

   Deliberately not SB-EXT:PROCESS-WAIT, and deliberately taking a PID rather
   than a process object: the caller has just handed its process object to
   PTY-CLOSE, which closes it, so SBCL's own bookkeeping for it is gone.
   %PROCESS-ALIVE-P asks the kernel instead (kill(pid, 0)).

   The deadline is the point.  Every wait in this file must be able to fail;
   an unbounded one here cannot even be interrupted, because PROCESS-WAIT
   parks in select(2) where SBCL cannot deliver a timeout.  Shape follows the
   deadline loop already used in packages/vcs/tests/vcs-tests.lisp."
  (let ((deadline (+ (get-internal-real-time)
                     (* deadline-seconds internal-time-units-per-second))))
    (loop
      ;; The signal-zero probe, spelled out here rather than calling
      ;; nerimux::%PROCESS-ALIVE-P. That function is a BOOTSTRAP internal
      ;; (src/server-multi-loop.lisp), and reaching it made this unit's test
      ;; system fail to compile on its own -- it only resolved because the full
      ;; suite loads bootstrap first. Same syscall, same semantics.
      (unless (and (integerp pid) (plusp pid)
                   (handler-case (progn (sb-posix:kill pid 0) t)
                     (sb-posix:syscall-error () nil)))
        (return t))
      (when (>= (get-internal-real-time) deadline)
        (return nil))
      (sleep 0.01))))

(describe "pty process table"
  (it "remembers-and-takes-processes-atomically"
    (let* ((master-fd (gensym "synthetic-master-"))
           (pty (list :synthetic)))
      (unwind-protect
           (progn
             (expect (null (nerimux/pty::%take-pty-process master-fd)))
             (nerimux/pty::%remember-pty-process master-fd pty)
             (expect (eq pty (nerimux/pty::%take-pty-process master-fd)))
             (expect (null (nerimux/pty::%take-pty-process master-fd))))
        (nerimux/pty::%take-pty-process master-fd)))))

(describe "pty-unit-suite"

  ;;; ── %string-non-empty-p ──────────────────────────────────────────────────────

  ;; %string-non-empty-p returns T for a non-empty string.
  (it "string-non-empty-p-true-for-non-empty-string"
    (expect (nerimux/pty::%string-non-empty-p "hello") :to-be-truthy))

  ;; %string-non-empty-p returns NIL for an empty string.
  (it "string-non-empty-p-false-for-empty-string"
    (expect (nerimux/pty::%string-non-empty-p "") :to-be-falsy))

  ;; %string-non-empty-p returns NIL for NIL.
  (it "string-non-empty-p-false-for-nil"
    (expect (nerimux/pty::%string-non-empty-p nil) :to-be-falsy))

  ;; %string-non-empty-p returns NIL for non-string values.
  (it "string-non-empty-p-false-for-non-string"
    (expect (nerimux/pty::%string-non-empty-p 42) :to-be-falsy)
    (expect (nerimux/pty::%string-non-empty-p '(a b)) :to-be-falsy))

  ;;; ── %spawn-directory ─────────────────────────────────────────────────────────

  ;; %spawn-directory returns NIL when START-DIR is NIL.
  (it "spawn-directory-nil-input-returns-nil"
    (expect (null (nerimux/pty::%spawn-directory nil))))

  ;; %spawn-directory returns NIL when START-DIR is an empty string.
  (it "spawn-directory-empty-string-returns-nil"
    (expect (null (nerimux/pty::%spawn-directory ""))))

  ;; %spawn-directory returns a non-NIL truename for an existing directory.
  (it "spawn-directory-existing-path-returns-truename"
    (let ((result (nerimux/pty::%spawn-directory "/tmp")))
      (expect result :to-be-truthy)))

  ;; %spawn-directory returns NIL for a non-existent directory path.
  ;; The simplified implementation uses ignore-errors so failures silently yield NIL.
  (it "spawn-directory-nonexistent-path-returns-nil"
    (let ((result (nerimux/pty::%spawn-directory
                   "/nonexistent/path/that/does/not/exist/xyz")))
      (expect (null result))))

  ;;; ── forkpty-with-shell reachability ─────────────────────────────────────────

  ;; forkpty-with-shell is exported from nerimux/pty and callable.
  (it "forkpty-with-shell-is-fbound"
    (expect (fboundp 'nerimux/pty:forkpty-with-shell)))

  ;; set-pty-size is exported from nerimux/pty and callable.
  (it "set-pty-size-is-fbound"
    (expect (fboundp 'nerimux/pty:set-pty-size)))

  (it "set-pty-size-forwards-columns-rows-and-fd-in-library-order"
    (let ((call nil))
      (with-stubbed-fdefinition
          ((cl-tty-kit:set-terminal-size
             (lambda (columns rows fd)
               (setf call (list columns rows fd)))))
        (nerimux/pty:set-pty-size 91 24 80))
      (expect (equal '(80 24 91) call))))

  (it "forkpty-with-shell-registers-the-spawned-pty"
    (let* ((pty (gensym "PTY-"))
           (master-fd 90123)
           (child-pid 45678)
           (spawn-arguments nil)
           (resize-call nil))
      (with-stubbed-fdefinition
          ((cl-tty-kit:make-pty
             (lambda (&rest arguments)
               (setf spawn-arguments arguments)
               pty))
           (cl-tty-kit:pty-fd
             (lambda (object)
               (declare (ignore object))
               master-fd))
           (cl-tty-kit:pty-pid
             (lambda (object)
               (declare (ignore object))
               child-pid))
           (nerimux/pty:set-pty-size
             (lambda (fd rows cols)
               (setf resize-call (list fd rows cols)))))
        (unwind-protect
             (multiple-value-bind (fd pid slave-path)
                 (nerimux/pty:forkpty-with-shell
                  24 80 :start-dir "/tmp" :default-command "echo hi"
                  :environment '("A=1"))
               (expect (= master-fd fd))
               (expect (= child-pid pid))
               (expect (string= "" slave-path))
               (expect (equal (list master-fd 24 80) resize-call))
               (expect (equal "/bin/sh" (getf spawn-arguments :program)))
               (expect (equal '("-c" "echo hi")
                              (getf spawn-arguments :args)))
               (expect (equal '("A=1") (getf spawn-arguments :environment)))
               (expect (pathnamep (getf spawn-arguments :directory)))
               (expect (eq pty (gethash master-fd nerimux/pty::*pty-processes*))))
          (nerimux/pty::%take-pty-process master-fd)))))

  (it "forkpty-with-shell-closes-the-pty-when-resize-fails"
    (let* ((pty (gensym "PTY-"))
           (master-fd 90124)
           (closed nil))
      (with-stubbed-fdefinition
          ((cl-tty-kit:make-pty (lambda (&rest arguments)
                                  (declare (ignore arguments))
                                  pty))
           (cl-tty-kit:pty-fd (lambda (object)
                                (declare (ignore object))
                                master-fd))
           (cl-tty-kit:pty-pid (lambda (object)
                                 (declare (ignore object))
                                 45679))
           (nerimux/pty:set-pty-size (lambda (&rest arguments)
                                       (declare (ignore arguments))
                                       (error "synthetic resize failure")))
           (cl-tty-kit:close-pty (lambda (object)
                                  (setf closed object))))
        (signals error
          (nerimux/pty:forkpty-with-shell 24 80))
        (expect (eq pty closed))
        (expect (null (gethash master-fd nerimux/pty::*pty-processes*))))))

  (it "pty-child-exit-status-reports-exit-and-signal-kinds"
    (let ((master-fd 90125)
          (processes nil))
      (labels ((start-process (command)
                 (let ((process (sb-ext:run-program
                                 "/bin/sh" (list "-c" command)
                                 :search t :wait nil :output nil :error nil)))
                   (push process processes)
                   process))
               (remember-process (process)
                 (nerimux/pty::%remember-pty-process
                  master-fd
                  (cl-tty-kit::%make-pty :process process :stream nil))))
        (unwind-protect
             (progn
               (remember-process (start-process "exit 17"))
               (multiple-value-bind (code kind)
                   (nerimux/pty:pty-child-exit-status
                    master-fd (cl-date-kit:duration-of-millis 1000))
                 (expect (= 17 code))
                 (expect (eq :exited kind)))
               (nerimux/pty::%take-pty-process master-fd)
               (remember-process (start-process "kill -TERM $$"))
               (multiple-value-bind (code kind)
                   (nerimux/pty:pty-child-exit-status
                    master-fd (cl-date-kit:duration-of-millis 1000))
                 (expect (numberp code))
                 (expect (eq :signaled kind))))
          (nerimux/pty::%take-pty-process master-fd)
          (dolist (process processes)
            (ignore-errors (sb-ext:process-wait process))
            (ignore-errors (sb-ext:process-close process)))))))

  ;; Never SB-EXT:PROCESS-WAIT on a process PTY-CLOSE has touched.
  ;;
  ;; PTY-CLOSE calls SB-EXT:PROCESS-CLOSE on this very process object as part
  ;; of its contract, so waiting on it afterwards waits on a handle whose
  ;; bookkeeping is already released and never completes.  That alone would be
  ;; a slow test; what makes it fatal is HOW it waits.  PROCESS-WAIT polls
  ;; through SERVE-ALL-EVENTS, i.e. select(2) -- a foreign call.  SBCL can only
  ;; deliver an interrupt at a safepoint, so a thread parked there is reachable
  ;; by neither SB-EXT:WITH-TIMEOUT nor INTERRUPT-THREAD: no deadline of any
  ;; kind can break it out.
  ;;
  ;; That is not hypothetical.  This test wedged the ENTIRE suite: the run
  ;; produced no output at all (every cl-weave reporter formats a collected
  ;; event list at the end, so a hung run prints nothing rather than stopping
  ;; visibly), CI hit its 30-minute job ceiling, and GitHub reported the
  ;; timeout as `cancelled' -- which reads as "someone cancelled it", not as a
  ;; failing test.
  ;;
  ;; Poll the PID instead.  %PROCESS-ALIVE-P asks the OS via kill(pid, 0)
  ;; rather than SBCL's released handle, and the deadline turns "the child
  ;; never died" into a red test instead of a wedged runner.
  (it "pty-close-signals-and-closes-a-registered-process"
    (let* ((process (sb-ext:run-program
                     "/bin/sh" '("-c" "exec sleep 60")
                     :search t :wait nil :output nil :error nil))
           (pty (cl-tty-kit::%make-pty :process process :stream nil))
           (master-fd 90126)
           (child-pid (sb-ext:process-pid process)))
      (unwind-protect
           (progn
             (nerimux/pty::%remember-pty-process master-fd pty)
             (nerimux/pty:pty-close master-fd child-pid)
             ;; The SIGHUP landed: the child is gone within the deadline.
             (expect (%wait-until-process-gone child-pid))
             (expect (null (gethash master-fd nerimux/pty::*pty-processes*))))
        ;; SIGKILL, not SIGHUP: cleanup must not depend on the very signal the
        ;; assertion above is testing, or a regression in PTY-CLOSE would leak
        ;; a 60-second sleeper into every later test in the run.
        (ignore-errors (sb-posix:kill child-pid sb-posix:sigkill))
        (ignore-errors (sb-ext:process-close process))
        (nerimux/pty::%take-pty-process master-fd))))

  (it "pty-close-closes-an-unregistered-fd-without-signalling"
    (with-pipe-fds (read-fd write-fd)
      (declare (ignorable write-fd))
      (nerimux/pty:pty-close read-fd 0)
      (expect (null (gethash read-fd nerimux/pty::*pty-processes*)))
      (signals sb-posix:syscall-error (sb-posix:close read-fd))))

  ;;; ── select-fds: the dead-pane fd sentinel ───────────────────────────────────

  (it "select-fds-helper-data-preserves-timeout-contract"
    (expect (null (nerimux/pty::%timeout-us-to-seconds -1)))
    (expect (= 0 (nerimux/pty::%timeout-us-to-seconds 0)))
    (expect (= 3/2 (nerimux/pty::%timeout-us-to-seconds 1500000)))
    (expect (equal '(0 7) (nerimux/pty::%selectable-fds '(-1 0 -4 7)))))

  ;; pane-fd -1 is nerimux's documented "no PTY / dead pane" sentinel, and the
  ;; event loop can still hold one in its poll set for the iteration in which a
  ;; pane is torn down.  process-kit's %validate-fds requires (INTEGER 0) and
  ;; raises a BARE TYPE-ERROR, which is NOT process-kit:fd-wait-failed and so is
  ;; NOT caught by select-fds' handler-case: without %selectable-fds the sentinel
  ;; is an unhandled error out of the event loop, where the hand-rolled %select
  ;; this replaced made it a silent no-op.
  (it "select-fds-drops-the-negative-fd-sentinel"
    (finishes (nerimux/pty:select-fds (list -1) 0)
              "select-fds must not signal on the pane-fd -1 sentinel")
    (expect (null (nerimux/pty:select-fds (list -1) 0))))

  ;; ...and dropping it must not collapse the whole poll: live fds in the same
  ;; call are still reported.  This is what filtering buys over widening the
  ;; handler-case to TYPE-ERROR, which would have returned NIL for the whole set.
  (it "select-fds-with-sentinel-still-reports-a-live-ready-fd"
    (with-pipe-fds (rfd wfd)
      (write-byte-to-fd wfd 99)
      (expect (equal (list rfd) (nerimux/pty:select-fds (list -1 rfd) 200000)))))

  ;;; ── pty-child-exit-status ────────────────────────────────────────────────────

  ;; pty-child-exit-status returns NIL for an fd with no registered process
  ;; (a foreign fd or a synthetic test pane never went through forkpty-with-shell).
  (it "pty-child-exit-status-unknown-fd-returns-nil"
    (expect (null (nerimux/pty:pty-child-exit-status 999999))))

  ;; The two properties pty-child-exit-status's bounded wait rests on, pinned
  ;; WITHOUT a PTY so they still hold on CI, where the live-child test in
  ;; tests/pty/pty-unit-tests.lisp and every other real-PTY test skip.  A hung
  ;; child there means the reader thread never returns from EOF handling, so
  ;; the deadline is the only thing keeping the server alive.
  ;;
  ;;  1. THE DEADLINE IS A BARE FORM.  cl-concurrent-kit's WITH-TIMEOUT takes a
  ;;     CL-DATE-KIT:DURATION as (with-timeout duration ...), not as
  ;;     bordeaux-threads' (bt:with-timeout (duration) ...).  Carrying the old
  ;;     parens over expands to (duration), calling the value as a function;
  ;;     passing a computed rather than literal duration keeps that distinction
  ;;     observable.
  ;;
  ;;  2. THE CONDITION IS AN ERROR.  SB-EXT:TIMEOUT is a SERIOUS-CONDITION that is
  ;;     deliberately NOT an ERROR, so pty.lisp's (error () nil) clause — the one
  ;;     sitting right beside (cl-concurrent-kit:operation-timed-out () nil) —
  ;;     would NOT have caught a raw sb-ext:timeout.  Only cl-concurrent-kit's
  ;;     translation makes either clause reachable; without it the timeout escapes
  ;;     pty-child-exit-status entirely instead of becoming its documented NIL.
  ;;
  ;; Asserted with a raw HANDLER-CASE rather than cl-weave's :to-throw for exactly
  ;; reason 2 — the same precedent as commands-tests-c.lisp's
  ;; with-timeout-signals-operation-timed-out-not-sb-ext-timeout.
  (it "pty-child-exit-status-deadline-is-a-bare-form-signalling-an-error"
    (let* ((duration (cl-date-kit:duration-of-millis 1)) ; computed, not literal
           (condition (handler-case
                          (cl-concurrent-kit:with-timeout duration (sleep 60))
                        (cl-concurrent-kit:operation-timed-out (c) c))))
      (expect (typep condition 'cl-concurrent-kit:operation-timed-out))
      (expect (typep condition 'error))
      (expect (not (typep condition 'sb-ext:timeout)))
      ;; The clause pty.lisp actually writes, exercised as written.
      (expect (null (handler-case
                        (cl-concurrent-kit:with-timeout duration (sleep 60))
                      (cl-concurrent-kit:operation-timed-out () nil))))))

  ;;; ── pty-write / pty-read-blocking-into (real pipe) ───────────────────────────

  ;; pty-write encodes a UTF-8 string and writes it to the fd; the bytes are
  ;; readable back via pty-read-blocking-into.
  (it "pty-write-string-round-trips-through-pipe"
    (with-pipe-fds (rfd wfd)
      (pty-write wfd "hi")
      (let ((result (pty-read-blocking-into rfd (make-array 16 :element-type '(unsigned-byte 8)))))
        (expect (equalp #(104 105) result)))))

  ;; pty-write accepts a raw octet vector and writes it verbatim.
  (it "pty-write-octet-vector-round-trips-through-pipe"
    (with-pipe-fds (rfd wfd)
      (pty-write wfd (make-array 3 :element-type '(unsigned-byte 8)
                                 :initial-contents '(1 2 3)))
      (let ((result (pty-read-blocking-into rfd (make-array 16 :element-type '(unsigned-byte 8)))))
        (expect (equalp #(1 2 3) result)))))

  ;; pty-write with a zero-length octet vector performs no write (no bytes land
  ;; on the read end).
  (it "pty-write-empty-octet-vector-is-noop"
    (with-pipe-fds (rfd wfd)
      (pty-write wfd (make-array 0 :element-type '(unsigned-byte 8)))
      (expect (null (nerimux/pty:select-fds (list rfd) 10000)))))

  (it "pty-read-blocking-into-maps-would-block-to-nil"
    (with-stubbed-fdefinition
        ((cl-tty-kit:fd-read-octets (lambda (&rest arguments)
                                      (declare (ignore arguments))
                                      nil)))
      (expect (null (nerimux/pty:pty-read-blocking-into
                     90128
                     (make-array 8 :element-type '(unsigned-byte 8)))))))

  (it "pty-write-ignores-the-negative-fd-sentinel"
    (finishes
      (nerimux/pty:pty-write
       -1 (make-array 1 :element-type '(unsigned-byte 8)
                      :initial-contents '(1)))))
  (it "pty-write-signals-sb-ext-timeout-when-the-underlying-write-hangs"
    (with-stubbed-fdefinition
        ((cl-tty-kit:fd-write-octets
           (lambda (&rest arguments)
             (declare (ignore arguments))
             ;; Well past +pty-write-timeout-seconds+ (2s) so with-timeout,
             ;; not this sleep completing, is what ends the call; short
             ;; enough that the test itself still finishes in a couple of
             ;; seconds.
             (sleep (+ nerimux/pty::+pty-write-timeout-seconds+ 1))
             0)))
      ;; CL-WEAVE:SIGNALS cannot express this.  Its :TO-THROW matcher goes
      ;; through THROWN-CONDITION (cl-weave 1.3.0,
      ;; src/matcher-runtime.lisp:153-161), which is
      ;;   (handler-case (progn (funcall thunk) nil) (error (c) c))
      ;; -- ERROR only.  SB-EXT:TIMEOUT is a SERIOUS-CONDITION deliberately
      ;; NOT an ERROR (the very asymmetry PEER-IO-FAILURE exists for), so it
      ;; sails straight through that handler and is reported as a test ERROR
      ;; rather than a caught signal.  commands-tests-c.lisp works around the
      ;; same limitation for CL-CONCURRENT-KIT:OPERATION-TIMED-OUT the same
      ;; way: catch it directly.
      ;;
      ;; Still proves boundedness.  Unbounded, the stub's sleep would return
      ;; normally, PTY-WRITE would return, the PROGN would yield NIL, and
      ;; (typep nil 'sb-ext:timeout) is NIL -- red.  Bounded, the timeout
      ;; fires first and TYPEP confirms the exact condition class.
      (expect (typep (handler-case
                         (progn
                           (nerimux/pty:pty-write
                            90129 (make-array 1 :element-type '(unsigned-byte 8)
                                                :initial-contents '(1)))
                           nil)
                       (sb-ext:timeout (condition) condition))
                     'sb-ext:timeout))))

  ;;; ── terminal-size ─────────────────────────────────────────────────────────────

  ;; terminal-size returns (values rows cols), both positive integers — either
  ;; the real ioctl-reported size or the documented fallback.
  (it "terminal-size-returns-two-positive-values"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (expect (integerp rows))
      (expect (integerp cols))
      (expect (plusp rows))
      (expect (plusp cols))))

  (it "terminal-size-swaps-library-values-and-falls-back-on-invalid-values"
    (let ((reported '(123 45)))
      (with-stubbed-fdefinition
          ((cl-tty-kit:terminal-size (lambda (fd)
                                        (declare (ignore fd))
                                        (apply #'values reported))))
        (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
          (expect (= 45 rows))
          (expect (= 123 cols)))
        (setf reported '(nil nil))
        (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
          (expect (= nerimux/pty:+default-term-rows+ rows))
          (expect (= nerimux/pty:+default-term-cols+ cols)))
        (setf reported '(1001 40))
        (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
          (expect (= nerimux/pty:+default-term-rows+ rows))
          (expect (= nerimux/pty:+default-term-cols+ cols))))))

  ;;; ── %target-program-and-args ─────────────────────────────────────────────────

  ;; %target-program-and-args routes a non-empty DEFAULT-COMMAND through /bin/sh -c
  ;; and does not request a PATH search.
  (it "target-program-and-args-with-default-command-uses-sh-c"
    (multiple-value-bind (program args search-p)
        (nerimux/pty::%target-program-and-args "echo hi")
      (expect (string= "/bin/sh" program))
      (expect (equal '("-c" "echo hi") args))
      (expect search-p :to-be-falsy)))

  ;; %target-program-and-args with a NIL/empty DEFAULT-COMMAND returns
  ;; %default-shell's result directly, with no extra args.  §1.4/R2.5: the
  ;; shell is $SHELL (or /bin/sh when unset), no longer a config option, so
  ;; the fixture stubs the real process environment rather than an option
  ;; table (tests/helpers-overlay-assertions.lisp's
  ;; with-temporary-posix-environment-variable — the pattern
  ;; posix-port.lisp's environment-value docstring calls for).
  (it "target-program-and-args-nil-command-uses-default-shell"
    (with-temporary-posix-environment-variable ("SHELL" "/bin/zsh")
      (multiple-value-bind (program args search-p)
          (nerimux/pty::%target-program-and-args nil)
        (expect (string= "/bin/zsh" program))
        (expect (null args))
        (expect search-p :to-be-falsy))))

  ;; %target-program-and-args requests a PATH search (SEARCH-P = T) when
  ;; $SHELL is not an absolute path.
  (it "target-program-and-args-relative-shell-requests-path-search"
    (with-temporary-posix-environment-variable ("SHELL" "zsh")
      (multiple-value-bind (program args search-p)
          (nerimux/pty::%target-program-and-args "")
        (declare (ignore args))
        (expect (string= "zsh" program))
        (expect search-p :to-be-truthy))))

  ;;; ── install-pty-port ─────────────────────────────────────────────────────────

  ;; install-pty-port sets *spawn-pty*, *write-pty*, *resize-pty*, and *close-pty*
  ;; to the corresponding nerimux/pty functions.
  (it "install-pty-port-wires-all-four-ports"
    (let ((nerimux/ports:*spawn-pty*  nil)
          (nerimux/ports:*write-pty*  nil)
          (nerimux/ports:*resize-pty* nil)
          (nerimux/ports:*close-pty*  nil))
      (nerimux/pty:install-pty-port)
      (expect (eq #'nerimux/pty:forkpty-with-shell nerimux/ports:*spawn-pty*))
      (expect (eq #'nerimux/pty:pty-write nerimux/ports:*write-pty*))
      (expect (eq #'nerimux/pty:set-pty-size nerimux/ports:*resize-pty*))
      (expect (eq #'nerimux/pty:pty-close nerimux/ports:*close-pty*))))

  (it "pty-port-wrappers-forward-to-installed-functions"
    (let* ((spawn-call nil)
          (write-call nil)
          (resize-call nil)
          (close-call nil)
          (nerimux/ports:*spawn-pty*
            (lambda (rows cols &key start-dir default-command environment)
              (setf spawn-call (list rows cols start-dir default-command environment))
              (values 3 4 "/dev/pts/wrapper")))
          (nerimux/ports:*write-pty*
            (lambda (fd bytes)
              (setf write-call (list fd bytes))
              :written))
          (nerimux/ports:*resize-pty*
            (lambda (fd rows cols)
              (setf resize-call (list fd rows cols))
              :resized))
          (nerimux/ports:*close-pty*
            (lambda (fd pid)
              (setf close-call (list fd pid))
              :closed)))
      (multiple-value-bind (fd pid tty)
          (nerimux/ports:spawn-pty
           24 80 :start-dir "/tmp" :default-command "echo hi"
           :environment '("A=1"))
        (expect (= 3 fd))
        (expect (= 4 pid))
        (expect (string= "/dev/pts/wrapper" tty)))
      (expect (equal '(24 80 "/tmp" "echo hi" ("A=1")) spawn-call))
      (let ((bytes (make-array 2 :element-type '(unsigned-byte 8)
                               :initial-contents '(7 8))))
        (expect (eq :written (nerimux/ports:write-pty 9 bytes)))
        (expect (= 9 (or (first write-call) -1)))
        (expect (equalp bytes (second write-call))))
      (expect (eq :resized (nerimux/ports:resize-pty 9 30 100)))
      (expect (equal '(9 30 100) resize-call))
      (expect (eq :closed (nerimux/ports:close-pty 9 10)))
      (expect (equal '(9 10) close-call))))

  ;;; ── terminal-size fallback constants ─────────────────────────────────────────

  ;; +default-term-rows+ and +default-term-cols+ are the shared terminal-size
  ;; fallback constants (24x80), matching *term-rows*/*term-cols* defvar defaults.
  (it "default-term-rows-cols-are-positive-fixnums"
    (expect (= 24 nerimux/pty:+default-term-rows+))
    (expect (= 80 nerimux/pty:+default-term-cols+))))

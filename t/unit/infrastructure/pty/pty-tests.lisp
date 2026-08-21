(in-package #:nerimux/test)

;;;; Unit tests for pty.lisp: argument-assembly helpers.
;;;; These cover %spawn-directory and %string-non-empty-p without spawning a
;;;; real PTY process.  (The child-environment assignment logic now lives in
;;;; session-child-environment; see session-environment-tests.lisp.)

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

  ;;; ── forkpty-with-shell end-to-end (real PTY) ─────────────────────────────────

  ;; forkpty-with-shell spawns a real child shell and returns a non-negative
  ;; master fd and a positive pid.
  (it "forkpty-with-shell-returns-sane-fd-and-pid"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (expect (>= fd 0))
      (expect (plusp pid))))

  ;; forkpty-with-shell returns an empty string for slave-path (SBCL exposes no
  ;; portable slave path), not NIL.
  (it "forkpty-with-shell-slave-path-is-a-string"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (multiple-value-bind (fd pid slave-path) (forkpty-with-shell 24 80)
      (unwind-protect
           (expect (string= "" slave-path))
        (pty-close fd pid))))

  ;; set-pty-size applies ROWS and COLS to the right winsize fields on a real
  ;; spawned PTY master fd.
  ;;
  ;; READ-BACK IS THE POINT.  The previous version of this test only asserted
  ;; that the call did not signal, which cannot catch a rows/cols transposition:
  ;; set-terminal-size accepts 100x30 exactly as happily as 30x100, so an
  ;; inverted adapter passed silently.  The only other round-trip guard lives in
  ;; t/integration/pty-tests.lisp, and the whole integration suite is skipped
  ;; when no /dev/ptmx is available — i.e. on CI — so this was the transposition
  ;; regression's only chance of being caught in `nix develop` and it did not
  ;; take it.  30x100 is deliberately NON-SQUARE (and neither dimension matches
  ;; with-pty-shell's 24x80 spawn size), so a swap fails both assertions.
  ;; cl-tty-kit:terminal-size returns (values COLUMNS ROWS) — columns first.
  (it "set-pty-size-round-trips-non-square-size-on-real-pty"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (finishes (nerimux/pty:set-pty-size fd 30 100)
                "set-pty-size must not signal on a live PTY master fd")
      (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size fd)
        (expect (eql 100 cols))
        (expect (eql 30 rows)))))

  ;;; ── set-pty-size rejects degenerate dimensions ───────────────────────────────

  ;; cl-tty-kit:set-terminal-size demands POSITIVE dimensions and signals before
  ;; the ioctl; the cffi path it replaced passed a 0x0 winsize through and ignored
  ;; the -1 return.  Pinned here because NERIMUX/MODEL:PANE-REPOSITION's
  ;; (plusp width) / (plusp content-height) guard exists solely to keep a
  ;; degenerate layout away from this behaviour — if the kit ever went back to
  ;; tolerating 0, that guard would become dead code rather than stay load-bearing.
  (it "set-pty-size-signals-on-a-zero-dimension"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (signals error (nerimux/pty:set-pty-size fd 0 80))
      (signals error (nerimux/pty:set-pty-size fd 24 0))))

  ;;; ── select-fds: the dead-pane fd sentinel ───────────────────────────────────

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

  ;; pty-child-exit-status bounds its wait: a still-running child (never told
  ;; to exit) with a tiny override timeout returns NIL rather than blocking
  ;; forever on sb-ext:process-wait.
  (it "pty-child-exit-status-times-out-on-a-live-child"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (expect (null (nerimux/pty:pty-child-exit-status fd 0.05)))))

  ;; The two properties pty-child-exit-status's bounded wait rests on, pinned
  ;; WITHOUT a PTY so they still hold on CI, where the live-child test above and
  ;; every other real-PTY test in this file skip.  A hung child there means the
  ;; reader thread never returns from EOF handling, so the deadline is the only
  ;; thing keeping the server alive.
  ;;
  ;;  1. THE DEADLINE IS A BARE FORM.  cl-concurrent-kit's WITH-TIMEOUT is shaped
  ;;     like SB-EXT:WITH-TIMEOUT — (with-timeout SECS ...) — not like
  ;;     bordeaux-threads' (bt:with-timeout (SECS) ...).  Carrying the old parens
  ;;     over expands to (SECS), calling the timeout VALUE as a function; passing
  ;;     a computed rather than literal deadline is what distinguishes the two.
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
    (let* ((seconds (/ 1 1000))              ; computed, not a literal
           (condition (handler-case
                          (cl-concurrent-kit:with-timeout seconds (sleep 60))
                        (cl-concurrent-kit:operation-timed-out (c) c))))
      (expect (typep condition 'cl-concurrent-kit:operation-timed-out))
      (expect (typep condition 'error))
      (expect (not (typep condition 'sb-ext:timeout)))
      ;; The clause pty.lisp actually writes, exercised as written.
      (expect (null (handler-case
                        (cl-concurrent-kit:with-timeout seconds (sleep 60))
                      (cl-concurrent-kit:operation-timed-out () nil)
                      (error () :wrong-clause))))))

  ;; pty-child-exit-status reports :exited with the real exit code once the
  ;; child has actually terminated.
  (it "pty-child-exit-status-reports-exited-code"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (multiple-value-bind (fd pid)
        (nerimux/pty:forkpty-with-shell 24 80 :default-command "exit 7")
      (unwind-protect
           (progn
             (sleep 0.3)
             (multiple-value-bind (code kind) (nerimux/pty:pty-child-exit-status fd)
               (expect (= 7 code))
               (expect (eq :exited kind))))
        (nerimux/pty:pty-close fd pid))))

  ;;; ── pty-write / pty-read-blocking (real pipe) ────────────────────────────────

  ;; pty-write encodes a UTF-8 string and writes it to the fd; the bytes are
  ;; readable back via pty-read-blocking.
  (it "pty-write-string-round-trips-through-pipe"
    (with-pipe-fds (rfd wfd)
      (pty-write wfd "hi")
      (let ((result (pty-read-blocking rfd 16)))
        (expect (equalp #(104 105) result)))))

  ;; pty-write accepts a raw octet vector and writes it verbatim.
  (it "pty-write-octet-vector-round-trips-through-pipe"
    (with-pipe-fds (rfd wfd)
      (pty-write wfd (make-array 3 :element-type '(unsigned-byte 8)
                                 :initial-contents '(1 2 3)))
      (let ((result (pty-read-blocking rfd 16)))
        (expect (equalp #(1 2 3) result)))))

  ;; pty-write with a zero-length octet vector performs no write (no bytes land
  ;; on the read end).
  (it "pty-write-empty-octet-vector-is-noop"
    (with-pipe-fds (rfd wfd)
      (pty-write wfd (make-array 0 :element-type '(unsigned-byte 8)))
      (expect (null (nerimux/pty:select-fds (list rfd) 10000)))))

  ;; pty-read-blocking returns NIL when the write end of the pipe is closed
  ;; before any data is written (EOF).
  (it "pty-read-blocking-returns-nil-on-eof"
    (with-pipe-fds (rfd wfd)
      (sb-posix:close wfd)
      (expect (null (pty-read-blocking rfd 16)))))

  ;;; ── terminal-size ─────────────────────────────────────────────────────────────

  ;; terminal-size returns (values rows cols), both positive integers — either
  ;; the real ioctl-reported size or the documented fallback.
  (it "terminal-size-returns-two-positive-values"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (expect (integerp rows))
      (expect (integerp cols))
      (expect (plusp rows))
      (expect (plusp cols))))

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
  ;; table (t/helpers-overlay-assertions.lisp's
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

  ;;; ── terminal-size fallback constants ─────────────────────────────────────────

  ;; +default-term-rows+ and +default-term-cols+ are the shared terminal-size
  ;; fallback constants (24x80), matching *term-rows*/*term-cols* defvar defaults.
  (it "default-term-rows-cols-are-positive-fixnums"
    (expect (= 24 nerimux/pty:+default-term-rows+))
    (expect (= 80 nerimux/pty:+default-term-cols+))))

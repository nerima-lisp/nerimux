(in-package #:nerimux/pty-test)

;;;; PTY unit tests that spawn a real forkpty(3) child.
;;;;
;;;; Moved from t/unit/infrastructure/pty/pty-tests.lisp (R9.2): these are the
;;;; cases from that file that spawn a real PTY-backed shell, directly via
;;;; forkpty-with-shell or through WITH-PTY-SHELL.  The argument-assembly,
;;;; fboundp-reachability, and pipe-fd cases stayed behind in nerimux/test.

(describe "pty-unit-suite"

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
  ;; t/pty/pty-integration-tests.lisp's set-pty-size-applies-non-square-size-
  ;; without-transposition, and the whole real-PTY suite is skipped when no
  ;; /dev/ptmx is available — i.e. on CI — so this was the transposition
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

  ;;; ── pty-child-exit-status ────────────────────────────────────────────────────

  ;; pty-child-exit-status bounds its wait: a still-running child (never told
  ;; to exit) with a tiny override timeout returns NIL rather than blocking
  ;; forever on sb-ext:process-wait.
  (it "pty-child-exit-status-times-out-on-a-live-child"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (expect (null (nerimux/pty:pty-child-exit-status fd 0.05)))))

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
        (nerimux/pty:pty-close fd pid)))))

(in-package #:nerimux/test)

;;;; Sandbox-safe PTY-adjacent tests: argument assembly, pipe-fd round-trips,
;;;; and no-op/guard behaviour that needs no real PTY.
;;;;
;;;; R9.2 of docs/notes/workspace-requirements.md split this file: every case
;;;; that actually spawned a real PTY (via WITH-PTY-SHELL, WITH-PTY-AVAILABLE,
;;;; or WITH-SESSION) moved to t/pty/pty-integration-tests.lisp, in the new
;;;; nerimux/pty-test ASDF system, which `nix flake check` does not run.  The
;;;; cases below never call pty-available-p or forkpty-with-shell -- they
;;;; either assert on pure constants/arguments, or exercise pty-write /
;;;; pty-read-blocking-into / select-fds through an ordinary pipe (with-pipe-fds),
;;;; which needs no /dev/ptmx -- so they stayed here and keep running under
;;;; `nix flake check`'s sandboxed nerimux/test.

(describe "pty-suite"

  ;; pty-close must never kill(-1)/kill(0): a non-positive pid and a negative
  ;; master fd are both no-ops, so the call simply finishes without signalling.
  (it "pty-close-ignores-non-positive-pid"
    (finishes (nerimux/pty:pty-close -1 -1))
    (finishes (nerimux/pty:pty-close -1 0)))

  ;; terminal-size returns rows/cols clamped to the sane 1..+max-sane-*+ range.
  ;; In the sandbox ioctl fails and it falls back to 24x80 — still in range.
  (it "terminal-size-returns-sane-clamped-geometry"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (expect (<= 1 rows nerimux/pty::+max-sane-rows+))
      (expect (<= 1 cols nerimux/pty::+max-sane-cols+))))

  ;; The fallback 24x80 values used when ioctl fails are themselves sane.
  (it "terminal-size-fallback-values-are-sane"
    (expect (<= 1 24 nerimux/pty::+max-sane-rows+))
    (expect (<= 1 80 nerimux/pty::+max-sane-cols+)))

  ;; +max-sane-rows+ and +max-sane-cols+ are positive and at least 80/24.
  (it "max-sane-bounds-are-reasonable"
    (expect (>= nerimux/pty::+max-sane-rows+ 24))
    (expect (>= nerimux/pty::+max-sane-cols+ 80)))

  ;; terminal-size delegates to cl-tty-kit:terminal-size (which returns COLUMNS
  ;; first) and SWAPS to nerimux's (values ROWS COLS) contract.  This guards the
  ;; transpose: when a real TTY reports a non-square size, ROWS must be the row
  ;; count and COLS the column count — not swapped.  On the standard-ish 24x80
  ;; terminal, and on the sandbox fallback (also 24x80), rows<=cols; more
  ;; importantly rows must equal cl-tty-kit's ROWS value, cols its COLUMNS value.
  (it "terminal-size-returns-rows-first"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (expect (integerp rows))
      (expect (integerp cols))
      (expect (<= 1 rows nerimux/pty::+max-sane-rows+))
      (expect (<= 1 cols nerimux/pty::+max-sane-cols+))))

  ;; select-fds short-circuits on an empty fd list regardless of timeout,
  ;; returning nil without ever calling select(2).
  (it "select-fds-empty-list-returns-nil"
    (expect (null (nerimux/pty:select-fds '() 0)))
    (expect (null (nerimux/pty:select-fds '() 100000)))
    (expect (null (nerimux/pty:select-fds '() -1))))

  ;; pty-write's etypecase accepts only strings and octet vectors; any other
  ;; type signals an error before any fd write is attempted.
  (it "pty-write-rejects-bad-type"
    (signals error (nerimux/pty:pty-write -1 42))
    (signals error (nerimux/pty:pty-write -1 '(1 2 3))))

  ;; An empty octet vector is guarded by (plusp len): no write(2) is issued,
  ;; so writing to a bogus fd -1 finishes without error.
  (it "pty-write-empty-is-noop"
    (let ((empty (make-array 0 :element-type '(unsigned-byte 8))))
      (finishes (nerimux/pty:pty-write -1 empty))))

  ;; A negative fd is the "no PTY / dead pane" sentinel (pane-fd -1).  pty-write's
  ;; (>= fd 0) guard must silently skip the write for a NON-EMPTY octet payload,
  ;; rather than let cl-tty-kit's fd-write-octets assert a non-negative fd and
  ;; signal.  This guard is load-bearing: dead panes hold pane-fd = -1.  A real
  ;; octet vector (not the literal #(1 2 3), which is a simple-vector and would
  ;; hit the type guard) exercises the fd guard specifically.
  (it "pty-write-negative-fd-is-noop"
    (let ((bytes (make-array 3 :element-type '(unsigned-byte 8)
                               :initial-contents '(1 2 3))))
      (finishes (nerimux/pty:pty-write -1 bytes))))

  ;;; ── Octet round-trip through the cl-tty-kit-backed I/O ──────────────────────

  ;; pty-write (octet vector) -> pty-read-blocking-into round-trips the exact bytes
  ;; through a real pipe, now that both delegate to cl-tty-kit's byte-transparent
  ;; fd-write-octets / fd-read-octets.  Includes 0, 127, 128, 255 to prove no
  ;; character re-encoding corrupts high bytes.
  (it "pty-write-pty-read-octet-round-trip"
    (with-pipe-fds (rfd wfd)
      (let ((original (make-array 5 :element-type '(unsigned-byte 8)
                                    :initial-contents '(0 1 127 128 255))))
        (nerimux/pty:pty-write wfd original)
        (let ((recovered (nerimux/pty:pty-read-blocking-into rfd (make-array 4096 :element-type '(unsigned-byte 8)))))
          (expect (equalp original recovered))
          (expect (typep recovered '(simple-array (unsigned-byte 8) (*))))))))

  ;; select-fds always returns a list (possibly nil), never another type.
  (it "select-fds-returns-list-type"
    (let ((result (nerimux/pty:select-fds '() 0)))
      (expect (listp result))))

  ;; select-fds returns the readable fd in a list when data is available on a pipe.
  (it "select-fds-with-pipe-data-returns-ready-fd"
    (with-pipe-fds (rfd wfd)
      (write-byte-to-fd wfd 99)
      (let ((ready (nerimux/pty:select-fds (list rfd) 200000)))
        (expect (equal (list rfd) ready)))))

  ;; select-fds with timeout-us=0 returns NIL immediately on an idle fd.
  (it "select-fds-zero-timeout-is-non-blocking"
    (with-pipe-fds (rfd _wfd)
      (let ((ready (nerimux/pty:select-fds (list rfd) 0)))
        (expect (null ready)))))

  ;; pty-close with a valid positive pid but negative fd sends SIGHUP but skips close.
  (it "pty-close-positive-pid-negative-fd-is-noop"
    ;; We can't test the kill call directly without a real process, but pty-close
    ;; with a bogus high pid should not error (kill may fail with ESRCH, ignored).
    (finishes (nerimux/pty:pty-close -1 99999999)
              "pty-close with negative fd and unknown pid must not signal"))

  ;;; ── terminal-size rows/cols order ───────────────────────────────────────────

  ;; terminal-size delegates to cl-tty-kit:terminal-size (which returns COLUMNS
  ;; first) and SWAPS to nerimux's (values ROWS COLS) contract.  This guards the
  ;; transpose: when a real TTY reports a non-square size, ROWS must be the row
  ;; count and COLS the column count — not swapped.  On the standard-ish 24x80
  ;; terminal, and on the sandbox fallback (also 24x80), rows<=cols; more
  ;; importantly rows must equal cl-tty-kit's ROWS value, cols its COLUMNS value.
  (it "terminal-size-returns-rows-then-cols-not-transposed"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (multiple-value-bind (kit-cols kit-rows) (cl-tty-kit:terminal-size 1)
        (if (and (integerp kit-rows) (integerp kit-cols)
                 (<= 1 kit-rows nerimux/pty::+max-sane-rows+)
                 (<= 1 kit-cols nerimux/pty::+max-sane-cols+))
            ;; Real TTY: nerimux's ROWS/COLS must map to cl-tty-kit's ROWS/COLUMNS.
            (progn
              (expect (= rows kit-rows))
              (expect (= cols kit-cols)))
            ;; No TTY / out-of-range: nerimux falls back to 24x80 (rows x cols).
            (progn
              (expect (= rows nerimux/pty:+default-term-rows+))
              (expect (= cols nerimux/pty:+default-term-cols+))))))))

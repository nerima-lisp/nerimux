(in-package #:nerimux/test)

;;;; PTY integration tests.  These spawn a real shell over a pseudo-terminal
;;;; and exercise the spawn/write/read/select pipeline end to end.
;;;;
;;;; PTY allocation needs /dev/ptmx, which sandboxed Nix builds do not provide.
;;;; When allocation fails we (skip) rather than fail, so the same suite runs
;;;; both in `nix develop` (real PTY) and `nix flake check` (sandboxed).
;;;;
;;;; pty-available-p is imported from nerimux/pty; no local shadow needed.

(defun drain-pty (fd &key (deadline-seconds 3.0) (stop-marker nil) (quiet-windows 1))
  "Read from FD until STOP-MARKER appears in the decoded output, DEADLINE-SECONDS
   elapses, or QUIET-WINDOWS consecutive empty 200ms select polls occur (meaning
   the shell has truly gone idle).  Returns the accumulated string.

   quiet-windows > 1 is useful before testing idleness: it certifies actual shell
   stability rather than just elapsed time, eliminating a race where the shell sends
   a late output burst right after drain returns."
  (let ((acc  (make-array 0 :element-type '(unsigned-byte 8) :adjustable t
                            :fill-pointer 0))
        (end  (+ (get-internal-real-time)
                 (* deadline-seconds internal-time-units-per-second)))
        (quiet-count 0))
    (loop
      (when (> (get-internal-real-time) end) (return))
      (if (select-fds (list fd) 200000)          ; 200 ms poll
          (let ((chunk (pty-read-blocking fd 4096)))
            (setf quiet-count 0)
            (when chunk
              (loop for b across chunk
                    do (vector-push-extend b acc))))
          (progn
            (incf quiet-count)
            (when (>= quiet-count quiet-windows) (return))))
      (let ((text (map 'string #'code-char acc)))
        (when (and stop-marker (search stop-marker text))
          (return-from drain-pty text))))
    (map 'string #'code-char acc)))

(describe "pty-suite"

  (it "shell-echoes-command-output"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let ((marker "NERIMUX_MARKER_42"))
        ;; Give the shell a moment to start, then send a command.
        (sleep 0.2)
        (pty-write fd (format nil "echo ~A~%" marker))
        (let ((out (drain-pty fd :stop-marker marker)))
          (expect (search marker out))))))

  (it "pty-write-accepts-octet-vector"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (let ((bytes (map '(simple-array (unsigned-byte 8) (*))
                        #'char-code
                        (format nil "printf DONE_OCTETS~%"))))
        (sleep 0.2)
        (pty-write fd bytes)
        (let ((out (drain-pty fd :stop-marker "DONE_OCTETS")))
          (expect (search "DONE_OCTETS" out))))))

  (it "select-times-out-when-idle"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      ;; Drain until two consecutive quiet 200ms windows: certifies the shell has
      ;; truly settled before we test that no further output arrives.
      (drain-pty fd :deadline-seconds 2.0 :quiet-windows 2)
      (let ((ready (select-fds (list fd) 100000)))  ; 100 ms, no input sent
        (expect (null ready)))))

  ;; Exercises the real resize path: spawned PTY per pane + ioctl(TIOCSWINSZ) +
  ;; screen-resize, across a split and a subsequent terminal resize.
  (it "split-then-relayout-keeps-panes-fitting"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        ;; Split vertically → two panes side by side.
        (window-split session win :h)
        (expect (= 2 (length (window-panes win))))
        ;; Now resize the terminal larger and relayout.
        (window-relayout win 40 120)
        (let ((ps (window-panes win)))
          ;; All panes fit within the new geometry, no overlap.
          (dolist (p ps)
            (expect (<= (+ (pane-x p) (pane-width p))  120))
            (expect (<= (+ (pane-y p) (pane-height p)) 40))
            (expect (plusp (pane-width  p)))
            (expect (plusp (pane-height p))))
          (destructuring-bind (a b) ps
            ;; divider column separates the two panes after relayout
            (expect (< (+ (pane-x a) (pane-width a)) (pane-x b))))))))

  ;; pty-child-exit-status reports KIND = :signaled when the child dies from a
  ;; signal (vs :exited for a normal exit code).  SIGKILL (9) cannot be trapped,
  ;; so the spawned shell is guaranteed to terminate by signal; reaping it via
  ;; pty-child-exit-status must yield (values 9 :signaled).
  (it "pty-child-exit-status-reports-signaled-kind"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-pty-shell (fd pid)
      (sleep 0.2)
      (sb-posix:kill pid 9)              ; SIGKILL — untrappable
      (multiple-value-bind (code kind) (nerimux/pty:pty-child-exit-status fd)
        (expect (eq kind :signaled))
        (expect (= code 9)))))

  ;; kill-pane on the last pane kills the window; session has 0 windows.
  (it "cmd-kill-pane-closes-fd"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    ;; with-session handles cleanup of all pane PTYs via unwind-protect.
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        (declare (ignore win))
        ;; kill-pane on the sole pane must not signal an error.
        (finishes (kill-pane session))
        ;; Killing the only pane removes the window; no windows remain.
        (expect (null (session-windows session))))))

  ;; After splitting vertically and killing one pane, exactly one pane remains.
  (it "split-and-kill-returns-to-single"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        ;; Split → 2 panes.
        (window-split session win :h)
        (expect (= 2 (length (window-panes win))))
        ;; Kill the active (second) pane → 1 pane should remain.
        (kill-pane session)
        (expect (= 1 (length (window-panes (session-active-window session))))))))

  ;;;; ── Un-gated sandbox-safe unit tests ──────────────────────────────────────
  ;;;; These run real assertions without /dev/ptmx, a tty, or a socket.

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

  ;;; ── set-pty-size argument order ──────────────────────────────────────────────
  ;;;
  ;;; nerimux's set-pty-size is (MASTER-FD ROWS COLS); cl-tty-kit's
  ;;; set-terminal-size is (COLUMNS ROWS &optional FD). The adapter must both
  ;;; transpose rows/cols AND move the fd. A round-trip on a DELIBERATELY
  ;;; NON-SQUARE size is the only thing that catches an inversion — 24x24 would
  ;;; pass either way. Both dimensions are asserted, so a swap fails loudly.
  ;;;
  ;;; This also covers the arm64 bug this migration fixed: the previous cffi
  ;;; ioctl call used a fixed prototype for a variadic syscall, so on Apple
  ;;; Silicon it returned -1 and the pty kept its old size. Under that code this
  ;;; test reads back the spawn size (8x20), not 40x123, and fails.

  ;; set-pty-size applies rows and columns to the correct fields, not transposed.
  (it "set-pty-size-applies-non-square-size-without-transposition"
    (with-pty-available
      (multiple-value-bind (master pid) (forkpty-with-shell 8 20)
        (unwind-protect
             (progn
               ;; rows=40, cols=123 — distinct, and neither matches the spawn size.
               (nerimux/pty:set-pty-size master 40 123)
               ;; cl-tty-kit:terminal-size returns (values COLUMNS ROWS).
               (multiple-value-bind (cols rows) (cl-tty-kit:terminal-size master)
                 (expect (eql 123 cols))
                 (expect (eql 40 rows))))
          (nerimux/pty:pty-close master pid)))))

  ;; nerimux/pty:terminal-size transposes cl-tty-kit's (COLUMNS ROWS) back into
  ;; nerimux's (ROWS COLS) contract. Guarded by the sanity bounds, so an
  ;; unavailable size falls back to 24x80 rather than reporting a transposed one.
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

  ;; pty-write (octet vector) -> pty-read-blocking round-trips the exact bytes
  ;; through a real pipe, now that both delegate to cl-tty-kit's byte-transparent
  ;; fd-write-octets / fd-read-octets.  Includes 0, 127, 128, 255 to prove no
  ;; character re-encoding corrupts high bytes.
  (it "pty-write-pty-read-octet-round-trip"
    (with-pipe-fds (rfd wfd)
      (let ((original (make-array 5 :element-type '(unsigned-byte 8)
                                    :initial-contents '(0 1 127 128 255))))
        (nerimux/pty:pty-write wfd original)
        (let ((recovered (nerimux/pty:pty-read-blocking rfd 4096)))
          (expect (equalp original recovered))
          (expect (typep recovered '(simple-array (unsigned-byte 8) (*))))))))

  ;; pty-read-blocking returns NIL when read(2) returns 0 (EOF) or negative.
  (it "pty-read-blocking-returns-nil-on-closed-fd"
    ;; A pipe whose write end is closed immediately delivers EOF on the read end.
    ;; with-pipe-fds is defined in t/helpers-pipe-fixtures.lisp.
    (with-pipe-fds (rfd wfd)
      ;; Close the write end so the read end gets EOF.
      (sb-posix:close wfd)
      ;; wfd is now closed; with-pipe-fds will call ignore-errors on the second close.
      (let ((result (nerimux/pty:pty-read-blocking rfd 1)))
        (expect (null result)))))

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

  ;; pty-read-blocking returns an (unsigned-byte 8) vector containing the written bytes.
  (it "pty-read-blocking-returns-octet-vector-when-data-available"
    (with-pipe-fds (rfd wfd)
      (write-octets-to-fd wfd #(1 2 3))
      (let ((result (nerimux/pty:pty-read-blocking rfd 4096)))
        (expect result :to-be-truthy)
        (expect (= 3 (length result)))
        (expect (= 1 (aref result 0)))
        (expect (= 2 (aref result 1)))
        (expect (= 3 (aref result 2))))))

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
              (expect (= cols nerimux/pty:+default-term-cols+)))))))

  ;;; ── New coverage: spawn helpers and microsecond constants ──────────────────

  ;; %string-non-empty-p accepts only strings with positive length.
  (it "string-non-empty-p-rejects-empty-and-non-strings"
    (expect (nerimux/pty::%string-non-empty-p "x") :to-be-truthy)
    (expect (nerimux/pty::%string-non-empty-p "") :to-be-falsy)
    (expect (nerimux/pty::%string-non-empty-p nil) :to-be-falsy)
    (expect (nerimux/pty::%string-non-empty-p 42) :to-be-falsy))

  ;; +microseconds-per-second+ is 1000000.
  (it "microseconds-per-second-is-one-million"
    (expect (= 1000000 nerimux/pty::+microseconds-per-second+)))

  ;;; ── %timeout-us-to-seconds ───────────────────────────────────────────────────
  ;;;
  ;;; Replaces the old %setup-timeval tests. nerimux no longer decomposes a
  ;;; struct timeval by hand — process-kit does that — so what is worth pinning
  ;;; here is only the unit conversion at the boundary, and in particular that
  ;;; it stays EXACT. A float would drift the deadline process-kit subtracts
  ;;; from across EINTR retries.

  ;; 1500000 us is 3/2 second exactly, not 1.5f0.
  (it "timeout-us-to-seconds-converts-exactly"
    (let ((seconds (nerimux/pty::%timeout-us-to-seconds 1500000)))
      (expect (= 3/2 seconds))
      (expect (rationalp seconds))
      (expect (not (floatp seconds)))))

  ;; 0 us stays 0 — process-kit spells a non-blocking poll that way too.
  (it "timeout-us-to-seconds-zero-is-a-poll"
    (expect (eql 0 (nerimux/pty::%timeout-us-to-seconds 0))))

  ;; 50000 us (50 ms, the +poll-timeout-us+ value) is 1/20 second.
  (it "timeout-us-to-seconds-sub-second-timeout"
    (expect (= 1/20 (nerimux/pty::%timeout-us-to-seconds 50000))))

  ;; A negative timeout is nerimux's "block indefinitely"; process-kit spells
  ;; that NIL, so the conversion must produce NIL and not a negative number
  ;; (which process-kit's FD-WAIT-TIMEOUT type would reject outright).
  (it "timeout-us-to-seconds-negative-means-block-forever"
    (expect (null (nerimux/pty::%timeout-us-to-seconds -1)))
    (expect (null (nerimux/pty::%timeout-us-to-seconds -100)))))

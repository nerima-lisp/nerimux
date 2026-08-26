;;;; Shared helpers for the e2e scenario files.
;;;;
;;;; Loaded (via plain LOAD, not ASDF) by e2e-smoke.lisp before any scenario
;;;; file, so every scenario -- headless or PTY-driven -- can rely on these
;;;; being defined.  This file itself never calls ASDF:LOAD-SYSTEM and never
;;;; touches a nerimux package: the headless scenarios in
;;;; server-kill-scenario.lisp must stay pure stock SBCL, and loading this
;;;; file is part of their path.

;;; SB-POSIX and ASDF (with UIOP) are contribs, not autoloaded. This file is
;;; loaded with plain LOAD (--script reads and evals form-by-form), so both
;;; REQUIREs must be their own top-level forms ahead of any defun below
;;; whose body the *reader* parses containing a symbol from either package
;;; -- inside a function body a REQUIRE would only run when later called,
;;; too late for the reader that already needs the package to exist just to
;;; intern the symbol.
(require :sb-posix)
(require :asdf)

;;; ── Byte-accumulator helpers (moved verbatim from the former e2e-smoke.lisp) ─

(defun %make-accumulator ()
  "Return a fresh adjustable byte vector for accumulating PTY output."
  (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))

(defun %accumulate-chunk (acc chunk)
  "Append CHUNK (octet vector) to ACC (adjustable fill-pointer vector)."
  (loop for b across chunk do (vector-push-extend b acc)))

(defun %search-in-tail (substr acc tail-size)
  "Search for SUBSTR (string) in the last TAIL-SIZE bytes of ACC (octet vector).
   Scanning only the tail avoids re-scanning gigabytes of prior PTY output."
  (let* ((len (fill-pointer acc))
         (start (max 0 (- len tail-size))))
    (search substr (map 'string #'code-char (subseq acc start)))))

;;; ── Bounded polling ───────────────────────────────────────────────────────
;;;
;;; Every wait in this suite goes through this one deadline-based loop rather
;;; than an unbounded blocking wait: SB-EXT:PROCESS-WAIT has no timeout of
;;; its own, and an unbounded wait on an already-exited process previously
;;; wedged this project's whole CI run by parking inside select(2) with no
;;; way out.

(defun poll-until (predicate timeout-seconds &key (interval-seconds 0.1))
  "Call PREDICATE (a thunk) repeatedly, sleeping INTERVAL-SECONDS between
   tries, until it returns non-NIL or TIMEOUT-SECONDS has elapsed since the
   first call. Returns PREDICATE's true value, or NIL on timeout. Always
   terminates; never blocks unboundedly."
  (let ((deadline (+ (get-internal-real-time)
                      (round (* timeout-seconds internal-time-units-per-second)))))
    (loop
      (let ((result (funcall predicate)))
        (when result (return result)))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep interval-seconds))))

;;; ── Process spawning ──────────────────────────────────────────────────────

(defun spawn-async (binary args)
  "Spawn BINARY with ARGS via SB-EXT:RUN-PROGRAM (no shell, :SEARCH NIL,
   :WAIT NIL), discarding its output. Returns the SB-EXT:PROCESS object; the
   caller is responsible for eventually reaping or killing it."
  (sb-ext:run-program binary args :output nil :error nil :search nil :wait nil))

(defun run-program-bounded (binary args &key (timeout-seconds 10))
  "Run BINARY with ARGS synchronously and capture its result, without ever
   blocking on SB-EXT:PROCESS-WAIT (which has no timeout parameter of its
   own). Polls process liveness instead via POLL-UNTIL.
   Returns (VALUES exit-code stdout stderr timed-out-p). A process still
   alive at the deadline is SIGKILLed; TIMED-OUT-P is then true and
   EXIT-CODE reflects whatever SBCL reports after the kill."
  (let* ((out (make-string-output-stream))
         (err (make-string-output-stream))
         (process (sb-ext:run-program binary args
                                       :output out :error err
                                       :search nil :wait nil)))
    (let ((exited (poll-until (lambda () (not (sb-ext:process-alive-p process)))
                               timeout-seconds)))
      (unless exited
        (ignore-errors (sb-ext:process-kill process 9))
        (poll-until (lambda () (not (sb-ext:process-alive-p process))) 2))
      ;; PROCESS-ALIVE-P going false only means the exit status is known; it
      ;; does not guarantee SBCL's pipe-copier threads have finished driving
      ;; the child's remaining stdout/stderr bytes into OUT/ERR. PROCESS-WAIT
      ;; joins that copying (and is not itself an unbounded wait here: the
      ;; process is already confirmed dead by the poll above, so this call
      ;; returns immediately -- it cannot re-park in select(2)).
      (sb-ext:process-wait process)
      (values (sb-ext:process-exit-code process)
              (get-output-stream-string out)
              (get-output-stream-string err)
              (not exited)))))

;;; ── Expected socket path ──────────────────────────────────────────────────

(defun %expected-socket-path (name)
  "The socket path RUN-SERVER binds for session NAME, computed the same way
   %SOCKET-TMP-BASE and SOCKET-PATH do (src/bootstrap/server.lisp:26-33,
   124-128): <TMPDIR-or-/tmp>/nerimux-<uid>/nerimux-<name>.sock. Duplicated
   here, rather than loaded from the nerimux system, because the headless
   scenarios that call this deliberately never load it."
  (let* ((tmpdir (sb-ext:posix-getenv "TMPDIR"))
         (base (string-right-trim
                "/"
                (if (and tmpdir (plusp (length tmpdir))) tmpdir "/tmp")))
         (uid (sb-posix:getuid)))
    (format nil "~A/nerimux-~D/nerimux-~A.sock" base uid name)))

;;; ── ASDF sibling-registry plumbing (attach scenario only) ────────────────

(defun %configure-asdf-registry (repo-root)
  "Configure ASDF's central registry exactly as run-tests.lisp does
   (run-tests.lisp:22-42), so ASDF:LOAD-SYSTEM :NERIMUX can find nerimux and
   its siblings from a script located under t/e2e/, not at the repo root
   run-tests.lisp assumes. REPO-ROOT is the nerimux checkout directory;
   NERIMUX_SIBLING_REGISTRY is a colon-separated list of sibling source
   roots, exactly as flake.nix supplies to run-tests.lisp."
  (require :asdf)
  (sb-impl::module-provide-contrib :sb-posix)
  (asdf:register-preloaded-system "sb-posix")
  (setf asdf/source-registry:*source-registry*
        (make-hash-table :test (function equal)))
  (push (truename repo-root) asdf:*central-registry*)
  (dolist (dir (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                                   :separator ":"))
    (unless (string= dir "")
      (push (truename (uiop:ensure-directory-pathname dir))
            asdf:*central-registry*))))

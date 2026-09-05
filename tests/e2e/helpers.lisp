(require :sb-posix)

(require :asdf)

(defun %make-accumulator ()
  "Return a fresh adjustable byte vector for accumulating PTY output."
  (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))

(defun %accumulate-chunk (acc chunk)
  "Append CHUNK (octet vector) to ACC (adjustable fill-pointer vector)."
  (loop for b across chunk
        do (vector-push-extend b acc)))

(defun %search-in-tail (substr acc tail-size)
  "Search for SUBSTR (string) in the last TAIL-SIZE bytes of ACC (octet vector).
   Scanning only the tail avoids re-scanning gigabytes of prior PTY output."
  (let* ((len (fill-pointer acc))
         (start (max 0 (- len tail-size))))
    (search substr (map 'string #'code-char (subseq acc start)))))

(defun poll-until (predicate timeout-seconds &key (interval-seconds 0.1))
  "Call PREDICATE (a thunk) repeatedly, sleeping INTERVAL-SECONDS between
   tries, until it returns non-NIL or TIMEOUT-SECONDS has elapsed since the
   first call. Returns PREDICATE's true value, or NIL on timeout. Always
   terminates; never blocks unboundedly."
  (let ((deadline
         (+ (get-internal-real-time)
            (round (* timeout-seconds internal-time-units-per-second)))))
    (loop (let ((result (funcall predicate)))
            (when result
              (return result))) (when (> (get-internal-real-time) deadline)
                                  (return nil)) (sleep interval-seconds))))

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
      (sb-ext:process-wait process)
      (values (sb-ext:process-exit-code process)
              (get-output-stream-string out)
              (get-output-stream-string err)
              (not exited)))))

(defun %expected-socket-path (name)
  "The socket path RUN-SERVER binds for session NAME, computed the same way
   %SOCKET-TMP-BASE and SOCKET-PATH do (src/bootstrap/server.lisp:26-33,
   124-128): <TMPDIR-or-/tmp>/nerimux-<uid>/nerimux-<name>.sock. Duplicated
   here, rather than loaded from the nerimux system, because the headless
   scenarios that call this deliberately never load it."
  (let* ((tmpdir (sb-ext:posix-getenv "TMPDIR"))
         (base
          (string-right-trim "/"
                             (if (and tmpdir (plusp (length tmpdir)))
                                 tmpdir
                                 "/tmp")))
         (uid (sb-posix:getuid)))
    (format nil "~A/nerimux-~D/nerimux-~A.sock" base uid name)))

(defun %configure-asdf-registry (repo-root)
  "Configure ASDF's central registry exactly as run-tests.lisp does
   (run-tests.lisp:22-42), so ASDF:LOAD-SYSTEM :NERIMUX can find nerimux and
   its siblings from a script located under tests/e2e/, not at the repo root
   run-tests.lisp assumes. REPO-ROOT is the nerimux checkout directory;
   NERIMUX_SIBLING_REGISTRY is a colon-separated list of sibling source
   roots, exactly as flake.nix supplies to run-tests.lisp."
  (require :asdf)
  (sb-impl::module-provide-contrib :sb-posix)
  (asdf:register-preloaded-system "sb-posix")
  (setf asdf/source-registry:*source-registry* (make-hash-table :test
                                                                (function equal)))
  (push (truename repo-root) asdf:*central-registry*)
  (dolist 
      (dir
       (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                          :separator
                          ":"))
    (unless (string= dir "")
      (push (truename (uiop:ensure-directory-pathname dir))
            asdf:*central-registry*))))

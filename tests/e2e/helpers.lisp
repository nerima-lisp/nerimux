(require :sb-posix)

(require :asdf)

(defparameter *e2e-environment-names*
  '("TMPDIR" "HOME" "XDG_STATE_HOME" "XDG_CONFIG_HOME" "XDG_CACHE_HOME"
    "XDG_DATA_HOME" "NERIMUX_RUNTIME_STATE" "SHELL"))

(defun call-with-isolated-e2e-environment (function &key cleanup)
  (let ((saved (mapcar (lambda (name)
                        (cons name (sb-ext:posix-getenv name)))
                      *e2e-environment-names*))
        (root (uiop:ensure-directory-pathname
               (sb-posix:mkdtemp "/tmp/nmx-e2e-XXXXXX")))
        (ready nil))
    (unwind-protect
         (unwind-protect
              (progn
                (dolist (name *e2e-environment-names*)
                  (sb-posix:setenv
                   name
                   (if (string= name "SHELL")
                       "/bin/sh"
                       (namestring
                        (ensure-directories-exist
                         (merge-pathnames (format nil "~A/" name) root))))
                   1))
                (format t "~&[e2e] isolated root ~A~%" root)
                (finish-output)
                (setf ready t)
                (funcall function root))
           ;; Keep the namespace for diagnosis if server cleanup fails.
           (when (and ready cleanup) (funcall cleanup root))
           (uiop:delete-directory-tree root :validate t)
           (when (probe-file root)
             (error "E2E isolation directory survived cleanup: ~A" root)))
      (dolist (entry saved)
        (if (cdr entry)
            (sb-posix:setenv (car entry) (cdr entry) 1)
            (sb-posix:unsetenv (car entry)))))))

(defun %make-accumulator ()
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
   first call. Returns PREDICATE's true value, or NIL on timeout.
   PREDICATE must return promptly; the deadline does not interrupt it."
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

(defun %read-output-snapshot (pathname)
  (with-open-file (stream pathname :element-type '(unsigned-byte 8))
    (let* ((bytes (make-array (file-length stream)
                              :element-type '(unsigned-byte 8)))
           (end (read-sequence bytes stream)))
      (sb-ext:octets-to-string bytes :end end))))

(defun run-program-bounded (binary args &key (timeout-seconds 10) (search nil))
  "Return (VALUES exit-code stdout stderr timed-out-p) for the direct child.
   On timeout, send SIGKILL and allow two seconds for termination, then
   signal an error if still alive. Capture output snapshots without waiting
   for descendants to close inherited handles. Descendants are not killed."
  (uiop:with-temporary-file (:stream out :pathname out-path :direction :output)
    (uiop:with-temporary-file (:stream err :pathname err-path :direction :output)
      (let ((process (sb-ext:run-program binary args :output out :error err
                                        :search search :wait nil)))
        (unwind-protect
             (let ((exited (poll-until
                            (lambda () (not (sb-ext:process-alive-p process)))
                            timeout-seconds)))
               (unless exited
                 (sb-ext:process-kill process 9)
                 (unless (poll-until
                          (lambda () (not (sb-ext:process-alive-p process))) 2)
                   (error "Child ~D did not terminate after SIGKILL"
                          (sb-ext:process-pid process))))
               (values (sb-ext:process-exit-code process)
                       (%read-output-snapshot out-path)
                       (%read-output-snapshot err-path)
                       (not exited)))
          (sb-ext:process-close process))))))

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

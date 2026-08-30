(in-package #:nerimux/test/input)

;;;; Tests for src/input.lisp: with-raw-mode macroexpansion + export checks
;;;; + read-byte-nonblock happy path via a sb-posix pipe pair.
;;;; with-raw-mode touches fd 0 (stdin) so it is verified by macroexpansion only.
;;;; read-byte-nonblock's select+read path is exercised with deterministic
;;;; function bindings, so no TTY or process-global stdin state is required.

(defmacro with-function-stubs ((&rest bindings) &body body)
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (list ,@(mapcar (lambda (binding)
                                    `(cons ',(first binding)
                                           (symbol-function ',(first binding))))
                                  bindings))))
       (unwind-protect
           (progn
             ,@(mapcar (lambda (binding)
                         `(setf (symbol-function ',(first binding))
                                (function ,(second binding))))
                       bindings)
             ,@body)
         (dolist (entry ,saved)
           (setf (symbol-function (car entry)) (cdr entry)))))))

(describe "input-suite"

  ;; The expansion calls enable-raw-mode! on fd 0 before evaluating BODY.
  (it "with-raw-mode-expands-enable-before-body"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form))
           (enable-pos (search "ENABLE-RAW-MODE!" text))
           (body-pos (search ":BODY-MARKER" text)))
      (expect enable-pos :to-be-truthy)
      (expect body-pos :to-be-truthy)
      (expect (< enable-pos body-pos))))

  ;; DISABLE-RAW-MODE! appears exactly once, in the unwind-protect cleanup.
  ;; No handler-bind: enable-raw-mode! runs outside the unwind-protect, and
  ;; cl-tty-kit's enable-raw-mode only records fd 0 as raw after its TCSETATTR
  ;; succeeds, so an error from enable-raw-mode! itself leaves nothing to
  ;; restore — a handler-bind calling disable-raw-mode! there would instead
  ;; run while enable-raw-mode!'s own raw-mode-states lock was still held on
  ;; the stack (handler-bind runs its handler before unwinding), recursing on
  ;; that lock from the same thread.
  (it "with-raw-mode-installs-disable-only-in-cleanup"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form))
           (count 0)
           (start 0))
      ;; Count non-overlapping occurrences of DISABLE-RAW-MODE! in the text.
      (loop for pos = (search "DISABLE-RAW-MODE!" text :start2 start)
            while pos
            do (incf count)
               (setf start (+ pos (length "DISABLE-RAW-MODE!"))))
      (expect (= 1 count))
      (expect (null (search "HANDLER-BIND" text)))
      (expect (search "UNWIND-PROTECT" text) :to-be-truthy)))

  ;; with-raw-mode is defined as a macro.
  (it "with-raw-mode-is-a-macro"
    (expect (macro-function 'nerimux/input::with-raw-mode) :to-be-truthy))

  ;; Public input symbols are exported and bound.
  (it "input-symbols-exported-and-fbound"
    ;; with-raw-mode is an exported macro.
    (expect (macro-function (find-symbol "WITH-RAW-MODE" '#:nerimux/input)) :to-be-truthy)
    ;; read-byte-nonblock is an exported function.
    (expect (fboundp (find-symbol "READ-BYTE-NONBLOCK" '#:nerimux/input)) :to-be-truthy)
    ;; Both names resolve as exported symbols of the package.
    (multiple-value-bind (sym status)
        (find-symbol "WITH-RAW-MODE" '#:nerimux/input)
      (declare (ignore sym))
      (expect (eq :external status)))
    (multiple-value-bind (sym status)
        (find-symbol "READ-BYTE-NONBLOCK" '#:nerimux/input)
      (declare (ignore sym))
      (expect (eq :external status))))

  ;; ── read-byte-nonblock happy path via pipe ───────────────────────────────────
  ;;
  ;; We use a POSIX pipe pair (sb-posix:pipe) so we can inject a known byte into
  ;; the read end without needing stdin to be a TTY.
  ;; with-pipe-fds is defined in tests/helpers-pipe-fixtures.lisp.

  ;; read-byte-nonblock's select+read pipeline returns a byte when data is ready.
  ;; Uses a pipe pair so no TTY is required.
  (it "read-byte-nonblock-returns-byte-when-data-available"
    (with-pipe-fds (rfd wfd)
      ;; Write one known byte into the write end.
      (write-byte-to-fd wfd 42)
      ;; Poll the read end: data should be ready immediately.
      (let ((ready (nerimux/pty:select-fds (list rfd) 200000)))  ; 200 ms timeout
        (expect ready :to-be-truthy)
        (when ready
          ;; Read exactly one byte (same mechanics as read-byte-nonblock, which
          ;; now goes through cl-tty-kit:fd-read-octets rather than cffi).
          (let ((bytes (read-octets-from-fd rfd 1)))
            (expect (= 1 (length bytes)))
            (expect (= 42 (aref bytes 0))))))))

  ;; select-fds returns NIL when no data is available within the timeout.
  ;; Verified on a fresh idle pipe.
  (it "read-byte-nonblock-select-returns-nil-when-no-data"
    (with-pipe-fds (rfd _wfd)
      ;; The pipe has no data; select with a short timeout must return NIL.
      (let ((ready (nerimux/pty:select-fds (list rfd) 10000)))  ; 10 ms
        (expect (null ready)))))

  ;; select-fds inspects the read-set ONLY when select(2) reports a positive count:
  ;; an idle pipe returns NIL (count 0 / EINTR -1 leave the read-set undefined), and
  ;; after a write the readable fd is reported.  This guards against an EINTR-driven
  ;; false positive on an idle fd.
  (it "select-fds-gates-on-positive-select-return"
    (with-pipe-fds (rfd wfd)
      ;; Idle pipe → NIL (gated; never inspects stale bits).
      (expect (null (nerimux/pty:select-fds (list rfd) 10000)))
      ;; Write one byte → select reports a positive count → the fd is returned.
      (write-byte-to-fd wfd 7)
      (expect (equal (list rfd) (nerimux/pty:select-fds (list rfd) 200000)))))

  ;; ── Package / constant coverage ─────────────────────────────────────────────

  ;; +poll-timeout-us+ is a positive fixnum used as the default select timeout.
  ;; It moved to nerimux/ports (posix-port.lisp) when nerimux/config was
  ;; deleted: a select-loop timing constant has no business living next to a
  ;; config-file loader, and now that the loader is gone there is nowhere
  ;; upward to depend on.
  (it "poll-timeout-us-constant-is-positive"
    (let ((timeout (symbol-value
                    (find-symbol "+POLL-TIMEOUT-US+" '#:nerimux/ports))))
      (expect (integerp timeout))
      (expect (plusp timeout))))

  ;; The expansion emits a format newline after restoring raw mode for clean output.
  (it "with-raw-mode-expansion-contains-format-newline"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form)))
      (expect (or (search "FORMAT" text) (search "format" text)) :to-be-truthy)))

  ;; ── select-fds empty-fd short-circuit via read-byte-nonblock path ────────────

  ;; read-byte-nonblock with timeout-us=0 is a purely non-blocking poll.
  ;; On a fresh idle pipe it must return NIL immediately.
  (it "read-byte-nonblock-with-zero-timeout-returns-nil-when-no-data"
    (with-pipe-fds (rfd _wfd)
      ;; Temporarily redirect the select call through read-byte-nonblock's
      ;; internal use of nerimux/pty:select-fds with the pipe read-end.
      ;; We cannot call read-byte-nonblock directly (it polls stdin fd 0), so
      ;; we validate the same mechanics: select-fds with timeout 0 on idle fd.
      (let ((ready (nerimux/pty:select-fds (list rfd) 0)))
        (expect (null ready)))))

  (it "read-byte-nonblock-covers-select-and-read-outcomes"
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore fds timeout-us))
                                   nil))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd buffer length))
                                      (error "read must not run"))))
      (expect (null (nerimux/input:read-byte-nonblock 0))))
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore timeout-us))
                                   fds))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd))
                                      (setf (aref buffer 0) 65)
                                      length)))
      (expect (= 65 (nerimux/input:read-byte-nonblock 0))))
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore timeout-us))
                                   fds))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd buffer length))
                                      0)))
      (expect (null (nerimux/input:read-byte-nonblock 0))))
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore timeout-us))
                                   fds))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd buffer length))
                                      (error 'cl-tty-kit:pty-operation-failed))))
      (expect (null (nerimux/input:read-byte-nonblock 0)))))

  ;; select-fds returns the fd in a ready list when data has been written.
  (it "read-byte-nonblock-select-returns-ready-list-when-data-present"
    (with-pipe-fds (rfd wfd)
      (write-byte-to-fd wfd 7)
      (let ((ready (nerimux/pty:select-fds (list rfd) 200000)))
        (expect (equal (list rfd) ready)))))

  ;; The expansion calls force-output to flush stdout after restoring the terminal.
  (it "with-raw-mode-expansion-has-force-output"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form)))
      (expect (or (search "FORCE-OUTPUT" text) (search "force-output" text)) :to-be-truthy))))

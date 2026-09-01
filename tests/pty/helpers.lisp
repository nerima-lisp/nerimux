(in-package #:nerimux/pty-test)

;;; ── PTY availability probe (test-only) ─────────────────────────────────────
;;;
;;; Moved verbatim from tests/helpers-pty-runtime.lisp (R9.2): nerimux/test no
;;; longer has any case that spawns a real PTY, so nothing there needs this
;;; probe any more.  pty-available-p is a testing artifact: it spawns a real
;;; shell and immediately kills it purely to check PTY access.  It lives here
;;; (test helpers) rather than in production source so the production pty.lisp
;;; has no test-only code.
(defun pty-available-p ()
  "Return T if a PTY-backed shell can be spawned on this system, NIL otherwise.
   Used as a skip guard in tests that require /dev/ptmx."
  (handler-case (multiple-value-bind (fd pid) (forkpty-with-shell 8 20)
                  (nerimux/pty:pty-close fd pid)
                  t)
    (error ()
      nil)))

(defmacro with-pty-available (&body body)
  "Run BODY when PTY-backed shells are available; otherwise SKIP the enclosing test.
   A bare (WHEN (PTY-AVAILABLE-P) ...) would leave the test reporting a PASS on a
   machine without /dev/ptmx, having asserted nothing — worse than a skip, because
   CI then looks clean.  cl-weave's SKIP invokes the SKIP-TEST restart, so the test
   is reported as skipped and the reason is printed."
  `(if (pty-available-p)
       (progn
         ,@body)
       (skip "PTY-backed shells are unavailable on this system (no /dev/ptmx?)")))

;;; with-pty-session (tests/helpers-pty-runtime.lisp's fake-session + PTY-gate
;;; combinator) had zero callers among the cases moved here -- every moved
;;; case uses either WITH-PTY-SHELL or WITH-SESSION directly -- and it needs
;;; WITH-FAKE-SESSION, which is a nerimux/test-only fixture this system does
;;; not import.  Left out rather than carried over as unreachable code.
(defun %forkpty-with-retry (rows cols &key (attempts 3))
  "Spawn a PTY shell, retrying transient allocation failures.
   Even after pty-available-p succeeds, the sandboxed builder can transiently
   run out of PTYs (SBCL signals \"could not find a pty\"), so a one-shot
   spawn makes the suite flaky.  Returns (values fd pid), or NIL when every
   attempt failed."
  (loop repeat attempts
        do (handler-case (multiple-value-bind (fd pid) 
                             (forkpty-with-shell rows cols)
                           (return (values fd pid)))
             (error ()
               (sleep 0.1)))
        finally (return nil)))

(defmacro with-pty-shell ((fd-var pid-var &key (rows 24) (cols 80)) &body body)
  "Spawn a shell on a fresh PTY of ROWS×COLS; bind FD-VAR and PID-VAR.
   Closes the PTY via unwind-protect on exit, even if BODY signals.
   Skips the enclosing test when PTY allocation keeps failing transiently."
  `(multiple-value-bind (,fd-var ,pid-var) (%forkpty-with-retry ,rows ,cols)
     (if (null ,fd-var)
         (skip "PTY allocation failed transiently (sandboxed environment)")
         (unwind-protect 
             (progn
               ,@body)
           (pty-close ,fd-var ,pid-var)))))

;;; ── PTY port initialization ─────────────────────────────────────────────────
;;;
;;; Any test that creates a real pane (create-initial-session, session-new-window,
;;; respawn-pane) goes through nerimux/ports:spawn-pty.  Install the PTY adapter
;;; now so the port vars are non-NIL for the duration of the test run.
(nerimux/pty:install-pty-port)

;;; ── with-session (moved from tests/helpers-session-fixtures.lisp) ───────────────
;;;
;;; The ONLY consumers of WITH-SESSION were the real-PTY cases moved into this
;;; system (R9.2 case-by-case audit); nerimux/test's own with-fake-session /
;;; with-minimal-session cover every remaining case, so the macro moved here
;;; rather than staying duplicated in both places.
(defmacro with-session ((var rows cols) &body body)
  "Bind VAR to a fresh session of ROWS x COLS, run BODY, then close all PTYs."
  `(let ((,var (create-initial-session ,rows ,cols)))
     (unwind-protect 
         (progn
           ,@body)
       (dolist (p (all-panes ,var))
         (ignore-errors (pty-close (pane-fd p) (pane-pid p)))))))

;;; ── with-empty-registry (minimal re-implementation) ──────────────────────────
;;;
;;; nerimux/test's WITH-EMPTY-REGISTRY (tests/helpers-input-fixtures.lisp) is a thin
;;; wrapper over WITH-REGISTERED-SESSIONS, which still has other callers there
;;; (server-registry-tests.lisp) and so stayed put.  The two moved cases that
;;; needed it only ever call it with zero bindings, so this is the exact
;;; behavioural equivalent of that call shape, not a general reimplementation.
(defmacro with-empty-registry (&body body)
  "Bind *server-sessions* to NIL for the duration of BODY."
  `(let ((nerimux::*server-sessions* nil))
     ,@body))

;;; ── with-test-listener / %test-socket-path (duplicated) ──────────────────────
;;;
;;; nerimux/test's copies (tests/helpers-network-listener.lisp) stayed put: they are
;;; also used by protocol-command-malformed-utf8-tests.lisp, client-tests-support.lisp
;;; and server-multi-tests-loop.lisp, none of which spawn a real PTY.  Only one
;;; moved case (multi-socket-renders-live-pty-output) needs this, hence the
;;; duplicate here rather than a cross-system dependency.
(defun %test-socket-directory ()
  (let ((tmpdir (sb-ext:posix-getenv "TMPDIR")))
    (string-right-trim "/"
                       (if (and tmpdir
                                (plusp (length tmpdir))
                                (host-kit:directory-exists-p tmpdir))
                           tmpdir
                           "/tmp"))))

(defun %test-socket-path (label)
  "Unique throwaway socket path for LABEL (a descriptive tag embedded in the
   filename), under an existing $TMPDIR (or /tmp when unset or invalid)."
  (let ((dir (%test-socket-directory)))
    (format nil "~A/nerimux-~A-~D.sock" dir label (get-universal-time))))

(defmacro with-test-listener ((listener-var path-var path-form &key backlog)
                              &body
                              body)
  "Bind PATH-VAR to PATH-FORM and LISTENER-VAR to a listener on it for the
   extent of BODY, tearing both down afterwards.  Skips BODY (via cl-weave
   `skip`) when Unix-domain sockets are unavailable."
  `(if (nerimux/net:unix-socket-available-p)
       (let* ((,path-var ,path-form)
              (_ (ensure-directories-exist ,path-var))
              (,listener-var
               ,(if backlog
                    `(nerimux/net:make-listener ,path-var :backlog ,backlog)
                    `(nerimux/net:make-listener ,path-var))))
         (declare (ignore _))
         (unwind-protect 
             (progn
               ,@body)
           (nerimux/net:close-socket ,listener-var)
           (ignore-errors (delete-file ,path-var))))
       (skip "Unix-domain socket unavailable (sandbox)")))

;;; ── drain-pty (moved from tests/integration/pty-tests.lisp) ──────────────────────
;;;
;;; Its only caller was that file's real-PTY cases, which all moved here.
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
          (let ((chunk (pty-read-blocking-into fd (make-array 4096 :element-type '(unsigned-byte 8)))))
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

;;; ── make-no-pty-pane (duplicated) ────────────────────────────────────────────
;;;
;;; nerimux/test's copy (tests/helpers-pane-fixtures.lisp) stayed put: it is used
;;; throughout the no-PTY geometry/layout suites there.  Only one moved case
;;; (window-split-full-obeys-axis-minimums) needs it here.
(defun make-no-pty-pane (id x y w h)
  "Build a pane with no real PTY and a matching virtual screen."
  (make-pane :id
             id
             :x
             x
             :y
             y
             :width
             w
             :height
             h
             :fd
             -1
             :pid
             -1
             :screen
             (make-screen w h)))

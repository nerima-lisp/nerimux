(in-package #:nerimux)

;;;; Detach-attach client.
;;;;
;;;; A thin terminal: it puts its own stdin in raw mode, forwards keystrokes and
;;;; resizes to the server as protocol frames, and paints the rendered frames
;;;; the server sends back.  It holds no session state — all prefix handling and
;;;; rendering happen server-side, so the client is the same for any session.
;;;;
;;;; Event-loop decomposition:
;;;;   %maybe-send-resize    — pure resize check + frame send (testable without terminal)
;;;;   %forward-stdin-byte   — read one byte from stdin and forward it to the server
;;;;   %decode-server-frame  — pure: read one server frame, return disposition + text
;;;;   %receive-server-frame — effect boundary: call decode, then write text to stdout

;;; ── run-client event-loop helpers ───────────────────────────────────────────

(defun %maybe-send-resize (stream)
  "If *resize-pending* is set, clear it, sample the current terminal dimensions,
   update *term-rows* and *term-cols*, and send a +msg-resize+ frame on STREAM.
   Returns T when a resize frame was sent, NIL otherwise.
   This helper is extracted from the run-client event loop so the resize-dispatch
   path is independently testable without a live terminal."
  (when *resize-pending*
    (setf *resize-pending* nil)
    (multiple-value-setq (*term-rows* *term-cols*) (terminal-size))
    (send-frame stream (msg-resize *term-rows* *term-cols*))
    t))

(defun %forward-stdin-byte (stream)
  "Read one byte from stdin (non-blocking) and, if one is available, forward it
   to the server as a +msg-key+ frame on STREAM.  Returns T when a byte was
   forwarded, NIL when stdin had nothing ready."
  (let ((stdin-byte (read-byte-nonblock 0)))
    (when stdin-byte
      (send-frame stream (msg-key (vector stdin-byte)))
      t)))

(defun %decode-server-frame (stream)
  "Pure step: read one frame from the server STREAM and classify it.
   Returns (values disposition text) where:
     disposition  :exit    — server signalled end-of-session (+msg-bye+ or EOF);
                  :frame   — a rendered screen frame was received;
                  :ignore  — an unrecognised frame type (continue event loop).
     text         the decoded string payload for a :frame disposition, NIL otherwise.
   No I/O side effects — the caller (%receive-server-frame) decides what to write."
  (with-incoming-frame (type payload stream)
    ((null type)        (values :exit nil))
    ((= type +msg-bye+) (values :exit nil))
    ((= type +msg-frame+)
     (values :frame (decode-text payload)))
    (t (values :ignore nil))))

(defun %receive-server-frame (stream)
  "Effect boundary: read and dispatch one frame from the server STREAM.
   Calls %decode-server-frame (pure), then writes any :frame text to
   *standard-output* (the only side-effecting step).
   Returns :exit when the server signals end-of-session (+msg-bye+ or EOF),
   NIL to continue the event loop."
  (multiple-value-bind (disposition text) (%decode-server-frame stream)
    (case disposition
      (:exit   :exit)
      (:frame  (write-string text) (force-output) nil)
      (t       nil))))

;;; ── run-client ───────────────────────────────────────────────────────────────

(defun %receive-if-ready (stream server-socket-fd ready)
  "If SERVER-SOCKET-FD appears in the READY fd list, read and dispatch one server
   frame from STREAM via %receive-server-frame.  Returns :exit when the server
   signals end-of-session, NIL otherwise (including when the fd was not ready).
   Completes the naming symmetry with %maybe-send-resize and %forward-stdin-byte:
   every run-client event-loop action is a named helper so all three are
   independently unit-testable without driving the full attach loop."
  (when (member server-socket-fd ready)
    (%receive-server-frame stream)))

(defun %client-working-directory ()
  (let ((defaults *default-pathname-defaults*))
    (or (handler-case (namestring (truename defaults))
          (file-error () nil))
        (and (pathnamep defaults) (namestring defaults))
        "")))

(defun %send-client-attach-target (stream target)
  (send-frame stream
              (msg-command :attach-target nil
                           (list (or target "")
                                 (%client-working-directory)))))

(defun run-client (name &key target)
  "Attach to the server at (socket-path NAME): forward stdin + resizes, render
   the frames the server returns, and exit on detach / server close.
   TARGET is an optional explicit organization/repository/worktree selector;
   the current working directory is sent for cwd-based attach selection."
  (require :sb-posix)
  (let ((socket (connect-to (socket-path name))))
    (unwind-protect
         (let ((stream           (socket-stream socket))
               (server-socket-fd (socket-fd socket)))
           (multiple-value-setq (*term-rows* *term-cols*) (terminal-size))
           (setf *resize-pending* nil)
           (install-sigwinch-handler)
           (with-raw-mode
             (clear-display)
             (send-frame stream (msg-attach *term-rows* *term-cols*))
             (%send-client-attach-target stream target)
             (loop
               (%maybe-send-resize stream)
               (let ((ready (select-fds (list 0 server-socket-fd) +poll-timeout-us+)))
                 (when (member 0 ready)
                   (%forward-stdin-byte stream))
                 (when (eq :exit (%receive-if-ready stream server-socket-fd ready))
                   (return))))))
      (close-socket socket))))

;;; ── nerimux kill (R8.1) ──────────────────────────────────────────────────
;;;
;;; A one-shot control connection: connect, send one +msg-command+, read back
;;; the +msg-reply+ the server's `:kill` command handler sends (that handler
;;; lives in server-multi-dispatch-command.lisp, out of this file's scope -- see the
;;; interface reported alongside this change), then disconnect.  It never
;;; sends +msg-attach+, so it is not RUN-CLIENT above -- but the server
;;; registers any accepted connection as a full client (%add-client,
;;; server-multi.lisp) before it ever reads a frame, so this connection is
;;; briefly a *clients* member and can receive an ordinary +msg-frame+
;;; broadcast (server-multi.lisp's %broadcast-frame, which runs once per
;;; event-loop iteration ahead of message dispatch) before its reply
;;; arrives.  %read-kill-reply discards those instead of mistaking one for
;;; "no reply".

(defun %read-kill-reply (stream)
  "Read frames from STREAM until a +msg-reply+ arrives or the connection
   ends, discarding any interleaved +msg-frame+ broadcast in between (see
   the section comment above).  Returns (values :reply TEXT) or
   (values :eof NIL).  Bounded by read-frame's own +read-frame-timeout-
   seconds+ per call, so a server that never replies does not hang this
   forever."
  (loop
    (multiple-value-bind (type payload) (read-frame stream)
      (cond
        ((null type) (return (values :eof nil)))
        ((= type +msg-bye+) (return (values :eof nil)))
        ((= type +msg-reply+) (return (values :reply (decode-text payload))))
        (t nil)))))

(defun %parse-kill-reply-status (text)
  "Classify a kill command's +msg-reply+ TEXT: the server-side contract
   (server-multi-dispatch-command.lisp, out of scope here) is that the first line is
   literally \"OK\" or \"DENIED\".  Anything else -- an empty reply, a typo,
   a future reply shape this client does not know about -- is read as
   :denied so an unrecognized reply fails closed rather than reporting a
   kill succeeded when it is not certain."
  (let* ((newline    (position #\Newline text))
         (first-line (if newline (subseq text 0 newline) text)))
    (if (string= first-line "OK") :ok :denied)))

(defun send-kill-request (name force-p)
  "Connect to (socket-path NAME), send a `:kill` command (R8.1), and return
   (values STATUS TEXT).  STATUS is :ok (the server accepted the kill and is
   shutting down), :denied (live panes refused it; TEXT lists them, one per
   line, from the server's reply), or :eof (the connection ended with no
   reply).  FORCE-P asks the server to SIGHUP then SIGKILL every live pane
   instead of refusing.
   Connection failure (no server running at NAME) is not caught here: it
   propagates as an ERROR, handled the same way main() already handles any
   other startup error (main-startup.lisp)."
  (let ((socket (connect-to (socket-path name))))
    (unwind-protect
         (let ((stream (socket-stream socket)))
           (send-frame stream
                       (msg-command :kill nil
                                    (when force-p (list "--force"))))
           (multiple-value-bind (disposition text) (%read-kill-reply stream)
             (if (eq disposition :reply)
                 (values (%parse-kill-reply-status text) text)
                 (values :eof nil))))
      (close-socket socket))))

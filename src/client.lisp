(in-package #:nerimux)

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
  "Read one frame from server STREAM and return its pure classification.
   Returns (values disposition text) where:
     disposition  :exit    — server signalled end-of-session (+msg-bye+ or EOF);
                  :frame   — a rendered screen frame was received;
                  :ignore  — an unrecognised frame type (continue event loop).
     text         the decoded string payload for a :frame disposition, NIL otherwise.
   The caller (%receive-server-frame) owns the output side effect."
  (with-incoming-frame (type payload stream)
                       ((null type) (values :exit nil))
                       ((= type +msg-bye+) (values :exit nil))
                       ((= type +msg-frame+)
                        (values :frame (decode-text payload)))
                       (t (values :ignore nil))))

(defun %receive-server-frame (stream)
  "Effect boundary: read and dispatch one frame from the server STREAM.
   Uses %decode-server-frame's pure classification step, then writes any :frame text to
   *standard-output* (the only side-effecting step).
   Returns :exit when the server signals end-of-session (+msg-bye+ or EOF),
   NIL to continue the event loop."
  (multiple-value-bind (disposition text) (%decode-server-frame stream)
    (case disposition
      (:exit :exit)
      (:frame
        (write-string text)
        (force-output)
        nil)
      (t nil))))

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
    (or
     (handler-case (namestring (truename defaults))
       (file-error ()
         nil))
     (namestring defaults)
     "")))

(defun %send-client-attach-target (stream target)
  (send-frame stream
              (msg-command :attach-target
                           nil
                           (list (or target "") (%client-working-directory)))))

(defun %run-attach-session (stream server-socket-fd target)
  "Send the initial handshake (msg-attach, then the attach-target command) on
   STREAM, then run the blocking stdin<->server relay loop until the server
   signals end-of-session or a PEER-IO-FAILURE (server.lisp) is caught.

   Extracted from RUN-CLIENT so this pure networking session (no terminal
   calls -- no WITH-RAW-MODE, TERMINAL-SIZE, or INSTALL-SIGWINCH-HANDLER) is
   independently testable with a socket pair, the same way
   %MAYBE-SEND-RESIZE / %FORWARD-STDIN-BYTE / %RECEIVE-IF-READY already are
   (see the file header's Event-loop decomposition note).

   PEER-IO-FAILURE is SB-EXT:TIMEOUT from a wedged peer, or any ERROR from
   the socket -- SEND-FRAME (infrastructure/net/transport.lisp) documents
   itself as signalling exactly the former when the peer is too slow to
   accept a write, and every send below reaches it.  The handshake sends and
   every send inside the loop are one continuous single-connection session:
   a failure at any point in it means the same thing, the connection is
   dead, so one HANDLER-CASE wraps the whole session rather than a separate
   one per SEND-FRAME call site.

   Unlike the server's WITH-LOOP-SAFE-ERROR (server-multi-dispatch.lisp),
   whose return value is a per-message loop disposition fed back into a
   dispatch table, this is a single blocking client loop with no caller
   waiting on a disposition: the right response is to report the failure to
   *ERROR-OUTPUT* and return, exactly as reaching :exit (+msg-bye+ / EOF)
   already does, so RUN-CLIENT's WITH-RAW-MODE still restores the terminal
   and its outer UNWIND-PROTECT still closes the socket."
  (handler-case (progn
                  (send-frame stream (msg-attach *term-rows* *term-cols*))
                  (%send-client-attach-target stream target)
                  (loop (%maybe-send-resize stream) (let ((ready
                                                           (select-fds
                                                            (list 0
                                                                  server-socket-fd)
                                                            +poll-timeout-us+)))
                                                      (when (member 0 ready)
                                                        (%forward-stdin-byte
                                                         stream))
                                                      (when 
                                                          (eq :exit
                                                              (%receive-if-ready
                                                               stream
                                                               server-socket-fd
                                                               ready))
                                                        (return)))))
    (peer-io-failure (c)
      (format *error-output* "~&nerimux: connection lost: ~A~%" c))))

(defun run-client (name &key target)
  "Attach to the server at (socket-path NAME): forward stdin + resizes, render
   the frames the server returns, and exit on detach / server close.
   TARGET is an optional explicit organization/repository/worktree selector;
   the current working directory is sent for cwd-based attach selection.
   The handshake and event loop are %RUN-ATTACH-SESSION (above); this
   function only owns the terminal/socket setup and teardown around it."
  (require :sb-posix)
  (let ((socket (connect-to (socket-path name))))
    (unwind-protect 
        (let ((stream (socket-stream socket))
              (server-socket-fd (socket-fd socket)))
          (multiple-value-setq (*term-rows* *term-cols*) (terminal-size))
          (setf *resize-pending* nil)
          (install-sigwinch-handler)
          (with-raw-mode (clear-display)
                         (%run-attach-session stream server-socket-fd target)))
      (close-socket socket))))

(defun %read-kill-reply (stream)
  "Read frames from STREAM until a +msg-reply+ arrives or the connection
   ends, discarding any interleaved +msg-frame+ broadcast in between (see
   the section comment above).  Returns (values :reply TEXT) or
   (values :eof NIL).  Bounded by read-frame's own +read-frame-timeout-
   seconds+ per call, so a server that never replies does not hang this
   forever."
  (loop (multiple-value-bind (type payload) (read-frame stream)
          (cond
            ((null type) (return (values :eof nil)))
            ((= type +msg-bye+) (return (values :eof nil)))
            ((= type +msg-reply+)
             (return (values :reply (decode-text payload))))
            (t nil)))))

(defun %parse-kill-reply-status (text)
  "Classify a kill command's +msg-reply+ TEXT: the server-side contract
   (server-multi-dispatch-command.lisp, out of scope here) is that the first line is
   literally \"OK\" or \"DENIED\".  Anything else -- an empty reply, a typo,
   a future reply shape this client does not know about -- is read as
   :denied so an unrecognized reply fails closed rather than reporting a
   kill succeeded when it is not certain."
  (let* ((newline (position #\Newline text))
         (first-line
          (if newline
              (subseq text 0 newline)
              text)))
    (if (string= first-line "OK")
        :ok
        :denied)))

(defun send-kill-request (name force-p)
  "Connect to (socket-path NAME), send a `:kill` command (R8.1), and return
   (values STATUS TEXT).  STATUS is :ok (the server accepted the kill and is
   shutting down), :denied (live panes refused it; TEXT lists them, one per
   line, from the server's reply), :eof (the connection ended with no
   reply), or :no-server (no server was running at NAME at all).  FORCE-P
   asks the server to SIGHUP then SIGKILL every live pane instead of
   refusing.
   A PEER-IO-FAILURE (runtime.lisp) on the SEND-FRAME below -- SB-EXT:TIMEOUT
   from a wedged peer, or any ERROR -- is treated exactly like :eof: no reply
   arrived either way, so this reuses RUN-KILL's existing \"no reply from
   server\" report (main-startup-commands.lisp) instead of inventing a second
   message for the same user-visible outcome.
   Connection failure (no server running at NAME) IS caught here, narrowly,
   around CONNECT-TO only: it signals SB-BSD-SOCKETS:SOCKET-ERROR both for a
   missing socket file (ENOENT) and for a stale one left behind by a server
   that has already died (ECONNREFUSED) -- either is turned into (values
   :no-server nil) so RUN-KILL (main-startup-commands.lisp) can print its
   \"no server running\" one-liner instead of the raw errno report.  A
   SOCKET-ERROR raised later
   in this function -- e.g. an ECONNRESET while reading the reply after a
   successful connect+send -- is a mid-session failure, not \"no server
   running\", and is deliberately left to propagate uncaught: narrowing the
   handler to just CONNECT-TO is the fix, since wrapping the whole function
   mislabelled that case."
  (let ((socket
         (handler-case (connect-to (socket-path name))
           (sb-bsd-sockets:socket-error ()
             (return-from send-kill-request
               (values :no-server nil))))))
    (unwind-protect 
        (let ((stream (socket-stream socket)))
          (handler-case (send-frame stream
                                    (msg-command :kill
                                                 nil
                                                 (when force-p
                                                   (list "--force"))))
            (peer-io-failure ()
              (return-from send-kill-request
                (values :eof nil))))
          (multiple-value-bind (disposition text) (%read-kill-reply stream)
            (if (eq disposition :reply)
                (values (%parse-kill-reply-status text) text)
                (values :eof nil))))
      (close-socket socket))))

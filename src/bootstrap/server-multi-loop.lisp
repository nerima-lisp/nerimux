(in-package #:nerimux)

;;; ── Event-loop iteration ────────────────────────────────────────────────────

;;; The server does not exit on its own.  Detaching the last client leaves the
;;; runtime and every pane running, and an empty session is not a reason to shut
;;; down either (R8.3 — both were options; neither is now).  The only ways out
;;; are an explicit kill and the confirm-view quit, both of which clear *RUNNING*.

(defun %accept-pending-connection (listener listener-fd ready)
  "When LISTENER-FD is in READY, accept and register the new connection.
   accept-connection may return NIL on a race (peer disappeared between
   select and accept), in which case nothing is registered."
  (when (member listener-fd ready)
    (let ((sock (accept-connection listener)))
      (when sock (%add-client sock)))))

(defun %read-and-dispatch-client-message (session conn)
  "Read one frame from CONN and dispatch it via %handle-multi-client-message.
   End-of-stream is returned as :eof so the server does not write a goodbye
   frame to a peer that has already closed.  Other read/decode errors are
   treated as a disconnect (:drop) so one malformed client cannot take down
   the multi-client event loop."
  (with-loop-safe-error (nil :on-error :drop)
    (multiple-value-bind (type payload) (read-frame (client-conn-stream conn))
      (if type
          (%handle-multi-client-message type payload session conn)
          :eof))))

(defun %apply-client-disposition (disposition conn)
  "Act on DISPOSITION (the result of dispatching CONN's message): drop CONN on
   :drop or :eof.  Returns :quit when the caller's loop must stop, else NIL.
   Dropping the last client is not a reason to stop — panes keep running while
   nobody is attached (R8.3)."
  (case disposition
    (:quit :quit)
    (:eof (%drop-client conn :bye nil) nil)
    (:drop (%drop-client conn :bye t) nil)))

(defun %dispatch-buffered-client-messages (session conn)
  "Dispatch the message select reported for CONN, then keep dispatching while
   CONN's stream still holds buffered input.  One read(2) can slurp several
   protocol frames into the Lisp stream's buffer — the client sends
   msg-attach and its attach-target command back-to-back, and they usually
   coalesce into one segment — after which the raw fd is no longer readable,
   so select alone would leave the buffered tail unread until some later
   keystroke arrived.  Returns :quit when a disposition ends the session."
  (loop
    (let ((disposition (%read-and-dispatch-client-message session conn)))
      (when (eq :quit (%apply-client-disposition disposition conn))
        (return :quit))
      ;; :drop and :eof closed CONN's socket; reading further would error.
      (when (member disposition '(:drop :eof))
        (return nil))
      (unless (handler-case (listen (client-conn-stream conn))
                (stream-error () nil))
        (return nil)))))

(defun %dispatch-ready-clients (session ready)
  "Read + dispatch pending messages from every client whose fd is in READY.
   Returns :quit as soon as any client's disposition ends the session, else NIL
   once every ready client has been served."
  (loop for conn in (copy-list *clients*)
        when (member (client-conn-fd conn) ready)
          do (when (eq :quit (%dispatch-buffered-client-messages session conn))
               (return :quit))))

(defun %multi-serve-iteration (listener session)
  "One iteration of the multi-client server loop: broadcast a dirty frame, then
   select on the listener fd + every client fd; accept a new connection when the
   listener is readable, and dispatch a message from each readable client.
   Returns :quit when the session must end, else NIL.  Factored out (taking the
   listener + session, mutating *clients*) so the dispatch/teardown logic is
   unit-testable without driving a full process loop."
  (%drain-main-thread-callbacks)
  (%broadcast-frame session)
  (let* ((listener-fd (socket-fd listener))
         (ready       (select-fds (cons listener-fd (%client-fds)) +poll-timeout-us+)))
    (when ready
      (%accept-pending-connection listener listener-fd ready)
      (%dispatch-ready-clients session ready))))

(defun %run-multi-server-loop (listener session)
  "Drive %multi-serve-iteration until *running* clears or a command ends the
   session.  Drops every remaining client (with a bye) on exit."
  (unwind-protect
       (loop while *running* do
         (when (eq :quit (%multi-serve-iteration listener session))
           (setf *running* nil)))
    (dolist (conn (copy-list *clients*))
      (%drop-client conn :bye t))))

;;; ── nerimux kill / C-q Q (R8.1, R8.2) ────────────────────────────────────
;;;
;;; %server-kill-request is the one function both entry points call:
;;;   - R8.1's `nerimux kill` command.  client.lisp's send-kill-request talks
;;;     to it over the socket; the +msg-command+ -> %server-kill-request
;;;     wiring itself belongs in server-multi-dispatch-command.lisp's
;;;     %handle-client-ui-command / %handle-multi-command-message, out of
;;;     this file's scope (see the report to team-lead for the exact case to
;;;     add and why %handle-multi-command-message needs a small change of
;;;     its own to let a :quit disposition through at all).
;;;   - R8.2's C-q Q, once R6.4's confirm view has shown the live-pane count
;;;     and the user answered y.  %workspace-prefix-quit-server
;;;     (server-multi-dispatch-prefix.lisp, the R8.2 stub) is also out of this
;;;     file's scope; it should call this function directly with FORCE-P T,
;;;     the same way a confirmed y answer already means "go ahead" for every
;;;     other R6.4 confirmation.

(defconstant +kill-sighup-grace-seconds+ 3
  "Grace period between SIGHUP and SIGKILL for `nerimux kill --force` and a
   confirmed C-q Q (R8.1/R8.2).  Long enough for an ordinary shell or REPL to
   flush and exit cleanly on SIGHUP; short enough that a forced kill does not
   hang a scripted caller for long.  There is no configuration knob for this
   (1.2 — config is gone), so the value is a constant rather than an option.")

(defun %session-live-panes (session)
  "Every pane across SESSION's windows whose PTY is still live (pane-live-p).
   R8.1's kill request reads this to decide whether a plain `nerimux kill`
   (no --force) must be refused, and R8.2's confirm view reads it to show
   the live-pane count before asking y/n."
  (remove-if-not #'pane-live-p (all-panes session)))

(defun %pane-kill-description (pane)
  "One line describing PANE for the `nerimux kill` refusal listing and the
   R6.4 confirm view: its id, pid, and worktree path (when it has one) so a
   caller can tell which pane to close before retrying."
  (format nil "pane ~D (pid ~D)~@[ in ~A~]"
          (pane-id pane) (pane-pid pane)
          (and (pane-worktree pane) (worktree-path (pane-worktree pane)))))

(defun %process-alive-p (pid)
  "T when PID still exists, probed with signal 0 (sends nothing; sb-posix:kill
   signals an OS error — ESRCH or EPERM alike — when it cannot see PID,
   which this reads as \"gone\" either way).  Used only by
   %force-kill-panes' SIGKILL escalation below, never as a substitute for
   pane-live-p's fd-based liveness check used everywhere else in this
   codebase."
  (require :sb-posix)
  (and (integerp pid) (plusp pid)
       (handler-case (progn (sb-posix:kill pid 0) t)
         (sb-posix:syscall-error () nil))))

(defun %force-kill-panes (panes)
  "R8.1/R8.2 --force path: close-pane-pty every PANE — the same SIGHUP +
   master-close every other pane-teardown call site already sends
   the multi-dispatch command/prefix files, runtime-reader.lisp:65, and
   server.lisp:126)
   — then wait +kill-sighup-grace-seconds+ and SIGKILL whichever pid is
   still alive.  Does not touch window/worktree bookkeeping (pane lists,
   active window, focus): the server process is about to exit, so there is
   no UI left to keep consistent."
  (require :sb-posix)
  (dolist (pane panes) (close-pane-pty pane))
  (sleep +kill-sighup-grace-seconds+)
  (dolist (pane panes)
    (when (%process-alive-p (pane-pid pane))
      (handler-case
          (sb-posix:kill (pane-pid pane) sb-posix:sigkill)
        (sb-posix:syscall-error () nil)))))

(defun %server-kill-request (session force-p)
  "Handle a kill request (R8.1's `nerimux kill`, and R8.2's C-q Q once
   confirmed): with live panes and no FORCE-P, returns
   (values :denied descriptions) without touching *running* — the caller
   turns that into a CLI refusal (R8.1) or leaves the confirm view up
   (R8.2, though R8.2's own confirm view already shows the live-pane count
   before offering y/n, so in practice its caller passes FORCE-P T and this
   branch is R8.1-only).  Otherwise force-kills any live panes when
   FORCE-P, then clears *running* so %run-multi-server-loop's own loop
   condition ends the process, and returns (values :ok nil)."
  (let ((live (%session-live-panes session)))
    (cond
      ((and live (not force-p))
       (values :denied (mapcar #'%pane-kill-description live)))
      (t
       (when live (%force-kill-panes live))
       (setf *running* nil)
       (values :ok nil)))))

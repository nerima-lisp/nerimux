(in-package #:nerimux)

;;; ── Event-loop iteration ────────────────────────────────────────────────────
;;; The server does not exit on its own.  Detaching the last client leaves the
;;; runtime and every pane running, and an empty session is not a reason to shut
;;; down either (R8.3 — both were options; neither is now).  The only ways out
;;; are an explicit kill and the confirm-view quit, both of which clear *RUNNING*.
(defun %accept-pending-connection (listener listener-fd ready)
  "When LISTENER-FD is in READY, accept and register the new connection.
   accept-connection may return NIL on a race (peer disappeared between
   select and accept), in which case nothing is registered.  A PEER-IO-FAILURE
   from accept itself (e.g. EMFILE fd exhaustion) is swallowed the same way:
   the failed accept is dropped rather than propagating out of the serve loop
   and killing the server out from under every already-attached client."
  (when (member listener-fd ready)
    (let ((sock
           (handler-case (accept-connection listener)
             (peer-io-failure ()
               nil))))
      (when sock
        (%add-client sock)))))

(defun %read-and-dispatch-client-message (session conn)
  "Read one frame from CONN and dispatch it via %handle-multi-client-message.
   End-of-stream is returned as :eof so the server does not write a goodbye
   frame to a peer that has already closed.  Other read/decode errors are
   treated as a disconnect (:drop) so one malformed client cannot take down
   the multi-client event loop."
  (with-loop-safe-error (nil :on-error :drop)
                        (multiple-value-bind (type payload) 
                            (read-frame (client-conn-stream conn))
                          (if type
                              (%handle-multi-client-message type
                                                            payload
                                                            session
                                                            conn)
                              :eof))))

(defun %apply-client-disposition (disposition conn)
  "Act on DISPOSITION (the result of dispatching CONN's message): drop CONN on
   :drop or :eof.  Returns :quit when the caller's loop must stop, else NIL.
   Dropping the last client is not a reason to stop — panes keep running while
   nobody is attached (R8.3)."
  (case disposition
    (:quit :quit)
    (:eof
      (%drop-client conn :bye nil)
      nil)
    (:drop
      (%drop-client conn :bye t)
      nil)))

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
         (ready (select-fds (cons listener-fd (%client-fds)) +poll-timeout-us+)))
    (when ready
      (%accept-pending-connection listener listener-fd ready)
      (%dispatch-ready-clients session ready))))

(defun %run-multi-server-loop (listener session)
  "Drive %multi-serve-iteration until *running* clears or a command ends the
   session.  Drops every remaining client (with a bye) on exit."
  (unwind-protect 
      (loop while *running*
            do (when (eq :quit (%multi-serve-iteration listener session))
                 (setf *running* nil)))
    (dolist (conn (copy-list *clients*))
      (%drop-client conn :bye t))))

;;; ── Server termination ─────────────────────────────────────────────────────
(defconstant +kill-sighup-grace-seconds+
  3)

(defun %session-live-panes (session)
  "Return the live panes in SESSION."
  (remove-if-not #'pane-live-p (all-panes session)))

(defun %pane-kill-description (pane)
  "Describe PANE for a refusal message."
  (format nil
          "pane ~D (pid ~D)~@[ in ~A~]"
          (pane-id pane)
          (pane-pid pane)
          (and (pane-worktree pane) (worktree-path (pane-worktree pane)))))

(defun %process-alive-p (pid)
  "Return true when PID accepts a signal-zero probe."
  (require :sb-posix)
  (and (integerp pid)
       (plusp pid)
       (handler-case (progn
                       (sb-posix:kill pid 0)
                       t)
         (sb-posix:syscall-error ()
           nil))))

(defun %force-kill-panes (panes)
  "Close PANES, then SIGKILL processes that outlive the grace period."
  (require :sb-posix)
  (dolist (pane panes)
    (close-pane-pty pane))
  (sleep +kill-sighup-grace-seconds+)
  (dolist (pane panes)
    (when (%process-alive-p (pane-pid pane))
      (handler-case (sb-posix:kill (pane-pid pane) sb-posix:sigkill)
        (sb-posix:syscall-error ()
          nil)))))

(defun %server-kill-request (session force-p)
  "Handle a kill request and return (VALUES status details)."
  (let ((live (%session-live-panes session)))
    (cond
      ((and live (not force-p))
       (values :denied (mapcar #'%pane-kill-description live)))
      (t
        (when live
          (%force-kill-panes live))
        (setf *running* nil)
        (values :ok nil)))))

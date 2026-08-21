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
   A read/decode error is treated as a disconnect (:drop) so one malformed or
   dropped client cannot take down the multi-client event loop."
  (with-loop-safe-error (nil :on-error :drop)
    (multiple-value-bind (type payload) (read-frame (client-conn-stream conn))
      (%handle-multi-client-message type payload session conn))))

(defun %apply-client-disposition (disposition conn)
  "Act on DISPOSITION (the result of dispatching CONN's message): drop CONN on
   :drop.  Returns :quit when the caller's loop must stop, else NIL.
   Dropping the last client is not a reason to stop — panes keep running while
   nobody is attached (R8.3)."
  (case disposition
    (:quit :quit)
    (:drop (%drop-client conn :bye t) nil)))

(defun %dispatch-ready-clients (session ready)
  "Read + dispatch one message from every client whose fd is in READY.
   Returns :quit as soon as any client's disposition ends the session, else NIL
   once every ready client has been served."
  (loop for conn in (copy-list *clients*)
        when (member (client-conn-fd conn) ready)
          do (let ((disposition (%read-and-dispatch-client-message session conn)))
               (when (eq :quit (%apply-client-disposition disposition conn))
                 (return :quit)))))

(defun %multi-serve-iteration (listener session)
  "One iteration of the multi-client server loop: broadcast a dirty frame, then
   select on the listener fd + every client fd; accept a new connection when the
   listener is readable, and dispatch a message from each readable client.
   Returns :quit when the session must end, else NIL.  Factored out (taking the
   listener + session, mutating *clients*) so the dispatch/teardown logic is
   unit-testable without driving a full process loop."
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

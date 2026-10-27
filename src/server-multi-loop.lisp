(in-package #:nerimux)

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

(defun %read-and-dispatch-client-message (session conn &key (max-bytes 65536))
  "Read one incremental frame and return disposition, status, and bytes consumed."
  (with-loop-safe-error (nil :on-error (values :drop :error 0))
    (let* ((reader (client-conn-frame-reader conn))
           (before (nerimux/transport::frame-reader-offset reader)))
      (multiple-value-bind (type payload status)
          (nerimux/transport:read-frame-ready
           reader (client-conn-socket conn) :max-bytes max-bytes)
        (let ((bytes-read
                (case status
                  (:frame
                   (- (+ nerimux/protocol:+header-size+ (length payload))
                      before))
                  (:pending
                   (- (nerimux/transport::frame-reader-offset reader) before))
                  (otherwise 0))))
          (case status
            (:frame
             (values (%handle-multi-client-message type payload session conn)
                     :frame
                     bytes-read))
            (:eof (values :eof :eof 0))
            (:pending (values nil :pending bytes-read))
            (:would-block (values nil :would-block 0))
            (otherwise
             (error "Unexpected frame reader status ~S" status))))))))

(defun %apply-client-disposition (disposition conn)
  "Act on DISPOSITION (the result of dispatching CONN's message): drop CONN on
   :drop or :eof.  Returns :quit when the caller's loop must stop, else NIL.
   Dropping the last client is not a reason to stop, panes keep running while
   nobody is attached (R8.3)."
  (case disposition
    (:quit :quit)
    (:eof (%drop-client conn :bye nil) nil)
    (:drop (%drop-client conn :bye t) nil)))

(defun %dispatch-buffered-client-messages (session conn)
  "Dispatch ready frames up to 64 KiB or 16 complete frames for this client."
  (loop with bytes-read = 0
        with complete-frames = 0
        while (and (< bytes-read 65536)
                   (< complete-frames 16))
        do (multiple-value-bind (disposition status received)
               (%read-and-dispatch-client-message
                session conn :max-bytes (- 65536 bytes-read))
             (incf bytes-read received)
             (case status
               (:frame
                (incf complete-frames)
                (let ((result (%apply-client-disposition disposition conn)))
                  (when (eq :quit result)
                    (return :quit))
                  (when (or (member disposition (list :drop :eof))
                            (not (member conn *clients* :test #'eq))
                            (client-conn-close-after-write-p conn))
                    (return nil))))
               (:eof
                (%apply-client-disposition :eof conn)
                (return nil))
               (:error
                (%apply-client-disposition disposition conn)
                (return nil))
               (otherwise
                (return nil))))))

(defun %dispatch-ready-clients (session ready)
  "Dispatch ready clients in a rotating order, each under its read quota."
  (let* ((ordered
           (%rotate-client-order (copy-list *clients*)
                                 *client-read-round-robin-cursor*))
         (ready-clients
           (remove-if-not
            (lambda (conn) (member (client-conn-fd conn) ready))
            ordered)))
    (when ready-clients
      (setf *client-read-round-robin-cursor* (first ready-clients)))
    (loop for conn in ready-clients
          when (member conn *clients* :test #'eq)
            do (when (eq :quit
                         (%dispatch-buffered-client-messages session conn))
                 (return :quit)))))

(defun %multi-serve-iteration (listener session)
  "Poll input first, service bounded ready work, then run maintenance and renders."
  (when *server-termination-requested-p*
    (setf *running* nil)
    (return-from %multi-serve-iteration :quit))
  (let* ((listener-fd (socket-fd listener))
         (previously-pending
           (remove-if-not #'%client-output-pending-p (copy-list *clients*)))
         (read-fds (cons listener-fd (%client-fds)))
         (write-fds (%client-write-fds))
         (timeout-us (%next-client-render-timeout-us
                      (get-internal-real-time))))
    (multiple-value-bind (read-ready write-ready)
        (select-fds read-fds timeout-us :write-fds write-fds)
      (%accept-pending-connection listener listener-fd read-ready)
      (let ((disposition (%dispatch-ready-clients session read-ready)))
        (%queue-session-control-output session)
        (%refresh-pending-client-render-frames session)
        (%flush-ready-client-output write-ready previously-pending)
        (when (eq :quit disposition)
          (return-from %multi-serve-iteration :quit))
        (%drain-main-thread-callbacks)
        (when *server-termination-requested-p*
          (setf *running* nil)
          (return-from %multi-serve-iteration :quit))
        (%workspace-job-tick)
        (%persist-runtime-state session)
        (%schedule-client-render-frames session)
        nil))))

(defun %run-multi-server-loop (listener session)
  "Drive %MULTI-SERVE-ITERATION until *RUNNING* clears or a command ends the
   session.  Drops every remaining client (with a bye) on exit."
  (unwind-protect
      (loop while *running*
            do (when (eq :quit (%multi-serve-iteration listener session))
                 (setf *running* nil)))
    (dolist (conn (copy-list *clients*))
      (%drop-client conn :bye t))
    (%flush-client-output :drain t)
    (dolist (conn (copy-list *clients*))
      (%drop-client conn))))


(defun %session-live-panes (session)
  "Return the live panes in SESSION."
  (remove-if-not (lambda (pane)
                   (or (pane-live-p pane)
                       (and (nerimux/pane:pane-stop-requested pane)
                            (not (nerimux/pane:pane-process-exited-p pane)))))
                 (all-panes session)))

(defun %pane-kill-description (pane)
  "Describe PANE for a refusal message as window:pane, the addressing the
   status bar shows.  Pane ids restart at 1 in every window, so the id alone
   names two different panes once a second window is open."
  (format nil
          "pane ~D:~D (pid ~D)~@[ in ~A~]"
          (window-id (pane-window pane))
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
  "Terminate and reap each owned pane process."
  (dolist (pane panes)
    (close-pane-pty pane)))

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

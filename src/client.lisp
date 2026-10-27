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
  "Read the available stdin burst once and forward it as one +msg-key+ frame."
  (let ((stdin-octets (read-available-octets 0 +pty-buf-size+)))
    (when stdin-octets
      (send-frame stream (msg-key stdin-octets))
      t)))

(defun %decode-server-frame (stream)
  "Read one frame from server STREAM and return its pure classification.
   Returns (values disposition text) where:
     disposition:
       :exit    server signalled end-of-session (+msg-bye+ or EOF);
       :frame   rendered screen frame was received;
       :parting the line to print after the terminal is restored (detach/quit);
       :ignore  unrecognised frame type (continue event loop).
     text         the decoded string payload for a :frame disposition, NIL otherwise;
     raw bytes    the original octet payload for a :notification disposition.
   The caller (%receive-server-frame) owns the output side effect."
  (with-incoming-frame (type payload stream)
                       ((null type) (values :exit nil))
                       ((= type +msg-bye+) (values :exit nil))
                       ((= type +msg-frame+)
                        (values :frame (decode-text payload)))
                       ((= type +msg-notification+)
                        (values :notification payload))
                       ((= type +msg-reply+)
                        (values :parting (decode-text payload)))
                       (t (values :ignore nil))))

(defun %write-notification-bytes (bytes)
  "Write BYTES to stdout without applying a character encoding."
  (let ((standard-output *standard-output*))
    (if (subtypep (stream-element-type standard-output)
                  '(unsigned-byte 8))
        (progn
          (write-sequence bytes standard-output)
          (force-output standard-output))
        (let ((binary-output
                (sb-sys:make-fd-stream 1
                                       :output t
                                       :element-type '(unsigned-byte 8)
                                       :buffering :none
                                       :auto-close nil)))
          (write-sequence bytes binary-output)
          (force-output binary-output)))))

(defun %receive-server-frame (stream)
  "Effect boundary: read and dispatch one frame from the server STREAM.
   Uses %decode-server-frame's pure classification step, then writes any :frame text to
   *standard-output* (the only side-effecting step).
   Returns :exit when the server signals end-of-session (+msg-bye+ or EOF),
   NIL to continue the event loop, and as a second value the parting line the
   caller prints once the terminal is back on its normal screen."
  (multiple-value-bind (disposition text) (%decode-server-frame stream)
    (case disposition
      (:exit :exit)
      (:frame
        (format t "~C[?2026h" #\Escape)
        (unwind-protect
             (progn
               (write-string text)
               (force-output))
          (format t "~C[?2026l" #\Escape)
          (force-output))
        nil)
      (:notification
        (%write-notification-bytes text)
        nil)
      (:parting (values nil text))
      (t nil))))

(defun %receive-if-ready (stream server-socket-fd ready)
  "If SERVER-SOCKET-FD appears in the READY fd list, read and dispatch one server
   frame from STREAM via %receive-server-frame.  Returns :exit when the server
   signals end-of-session, NIL otherwise (including when the fd was not ready),
   and passes through %receive-server-frame's parting line as a second value.
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

(defun %client-terminal-identity ()
  "Return the attach client's allow-listed terminal environment snapshot."
  (sort
   (loop for entry in (nerimux/ports:environment-entries)
         for separator = (and (stringp entry) (position #\= entry))
         for name = (and separator (subseq entry 0 separator))
         when (and name (%terminal-identity-variable-p name))
           collect (cons name (subseq entry (1+ separator))))
   #'string<
   :key #'car))

(defun %send-client-attach-target (stream target)
  (send-frame stream
              (msg-command :attach-target
                           nil
                           (list (or target "") (%client-working-directory)))))

(defun %paint-connecting-notice ()
  "Put one line on the alternate screen before the first server frame arrives
   (START-18).  Entering the alternate screen hides the host's own scrollback
   at once, and the handshake plus first render take long enough that the gap
   reads as a hang.  Every full frame opens with an erase-display, so the
   notice is painted over rather than left behind."
  (format t "nerimux: connecting...")
  (force-output))
(defconstant +client-output-limit+ (+ (* 64 1024 1024) 32))
(defparameter +client-sync-begin+
    (cl-codec-kit:string-to-octets (format nil "~C[?2026h" #\Escape)
                                    :encoding :utf-8))
(defparameter +client-sync-end+
    (cl-codec-kit:string-to-octets (format nil "~C[?2026l" #\Escape)
                                    :encoding :utf-8))
(defstruct (%client-output-item (:constructor %make-client-output-item (bytes kind)))
    bytes kind (offset 0))
(defstruct (%client-output-queue (:constructor %make-client-output-queue ()))
  head tail (bytes 0) (reserved 0) (limit +client-output-limit+))

(defun %client-enqueue-output (queue bytes &optional (kind :raw))
  (let ((size (length bytes)))
    (when (zerop size)
      (return-from %client-enqueue-output t))
    (when (> (+ (%client-output-queue-bytes queue)
                (%client-output-queue-reserved queue)
                size)
             (%client-output-queue-limit queue))
      (return-from %client-enqueue-output nil))
    (let ((cell (list (%make-client-output-item bytes kind))))
      (if (%client-output-queue-tail queue)
          (setf (cdr (%client-output-queue-tail queue)) cell)
          (setf (%client-output-queue-head queue) cell))
      (setf (%client-output-queue-tail queue) cell)
      (incf (%client-output-queue-bytes queue) size)
      t)))

(defun %client-reserve-output (queue size)
  (when (<= (+ (%client-output-queue-bytes queue)
               (%client-output-queue-reserved queue)
               size)
            (%client-output-queue-limit queue))
    (incf (%client-output-queue-reserved queue) size)
    t))

(defun %client-enqueue-reserved-output (queue bytes kind reservation)
  (decf (%client-output-queue-reserved queue) reservation)
  (let ((size (length bytes)))
    (when (plusp size)
      (let ((cell (list (%make-client-output-item bytes kind))))
        (if (%client-output-queue-tail queue)
            (setf (cdr (%client-output-queue-tail queue)) cell)
            (setf (%client-output-queue-head queue) cell))
        (setf (%client-output-queue-tail queue) cell)
        (incf (%client-output-queue-bytes queue) size)))
    t))
(defun %client-pop-output (queue)
    (let ((cell (%client-output-queue-head queue)))
      (when cell
        (setf (%client-output-queue-head queue) (cdr cell))
        (unless (%client-output-queue-head queue)
          (setf (%client-output-queue-tail queue) nil))
        (car cell))))
(defun %client-fd-flags (fd)
    (sb-posix:fcntl fd sb-posix:f-getfl))
(defun %client-set-nonblocking (fd)
    (let ((flags (%client-fd-flags fd)))
      (sb-posix:fcntl fd sb-posix:f-setfl (logior flags sb-posix:o-nonblock))
      flags))
(defun %client-restore-fd-flags (fd flags)
    (sb-posix:fcntl fd sb-posix:f-setfl flags))
(defun %client-would-block-p (condition)
    (let ((errno (sb-posix:syscall-errno condition)))
      (or (= errno sb-posix:eagain)
          (= errno sb-posix:ewouldblock))))
(defun %client-read-fd (fd buffer)
    (loop
      (handler-case
          (return-from %client-read-fd
            (sb-sys:with-pinned-objects (buffer)
              (let ((count (sb-posix:read fd (sb-sys:vector-sap buffer)
                                          (length buffer))))
                (values count (if (zerop count) :eof :data)))))
        (sb-posix:syscall-error (condition)
          (let ((errno (sb-posix:syscall-errno condition)))
            (cond
              ((= errno sb-posix:eintr))
              ((%client-would-block-p condition)
               (return-from %client-read-fd (values nil :would-block)))
              (t (error condition))))))))
(defun %client-write-fd (fd buffer start length)
    (loop
      (handler-case
          (return-from %client-write-fd
            (sb-sys:with-pinned-objects (buffer)
              (sb-posix:write fd
                              (sb-sys:sap+ (sb-sys:vector-sap buffer) start)
                              length)))
        (sb-posix:syscall-error (condition)
          (let ((errno (sb-posix:syscall-errno condition)))
            (cond
              ((= errno sb-posix:eintr))
              ((%client-would-block-p condition)
               (return-from %client-write-fd nil))
              (t (error condition))))))))
(defun %client-write-output-ready (queue &optional (output-fd 1))
    (let* ((cell (%client-output-queue-head queue))
           (item (and cell (car cell)))
           (bytes (and item (%client-output-item-bytes item)))
           (offset (and item (%client-output-item-offset item)))
           (remaining (and item (- (length bytes) offset))))
      (when (and remaining (plusp remaining))
        (let ((count (%client-write-fd output-fd bytes offset remaining)))
          (when count
            (incf (%client-output-item-offset item) count)
            (decf (%client-output-queue-bytes queue) count)
            (when (= (%client-output-item-offset item) (length bytes))
              (%client-pop-output queue)))))))
(defun %client-output-server-frame (queue type payload reservation)
  (case type
    (#.+msg-frame+
     (let* ((size (+ (length +client-sync-begin+)
                     (length payload)
                     (length +client-sync-end+)))
            (bytes (make-array size :element-type '(unsigned-byte 8))))
       (replace bytes +client-sync-begin+)
       (replace bytes payload :start1 (length +client-sync-begin+))
       (replace bytes +client-sync-end+
                :start1 (+ (length +client-sync-begin+) (length payload)))
       (%client-enqueue-reserved-output queue bytes :frame reservation)
       (values nil nil)))
    (#.+msg-notification+
     (%client-enqueue-reserved-output queue payload :raw reservation)
     (values nil nil))
    (#.+msg-reply+
     (decf (%client-output-queue-reserved queue) reservation)
     (values nil (decode-text payload)))
    (#.+msg-bye+
     (decf (%client-output-queue-reserved queue) reservation)
     (values :exit nil))
    (t
     (decf (%client-output-queue-reserved queue) reservation)
     (values nil nil))))
(defun %client-drop-pending-rendered-output (queue)
  (let ((new-head nil)
        (new-tail nil)
        (remaining-bytes 0))
    (loop for cell on (%client-output-queue-head queue)
          for item = (car cell)
          for bytes = (%client-output-item-bytes item)
          for offset = (%client-output-item-offset item)
          for kind = (%client-output-item-kind item)
          for remaining = (- (length bytes) offset)
          for replacement =
            (when (eq kind :frame)
              (cond
                ((zerop offset) nil)
                ((< offset (length +client-sync-begin+))
                 (concatenate '(simple-array (unsigned-byte 8) (*))
                              (subseq bytes offset
                                      (length +client-sync-begin+))
                              +client-sync-end+))
                ((< offset (- (length bytes)
                              (length +client-sync-end+)))
                 +client-sync-end+)
                (t (subseq bytes offset))))
          do (cond
               ((eq kind :frame)
                (when replacement
                  (let ((new-cell
                          (list (%make-client-output-item replacement
                                                          :sync-close))))
                    (if new-tail
                        (setf (cdr new-tail) new-cell)
                        (setf new-head new-cell))
                    (setf new-tail new-cell)
                    (incf remaining-bytes (length replacement)))))
               (t
                (let ((new-cell (list item)))
                  (if new-tail
                      (setf (cdr new-tail) new-cell)
                      (setf new-head new-cell))
                  (setf new-tail new-cell)
                  (incf remaining-bytes remaining)))))
    (setf (%client-output-queue-head queue) new-head
          (%client-output-queue-tail queue) new-tail
          (%client-output-queue-bytes queue) remaining-bytes
          (%client-output-queue-reserved queue) 0)
    queue))

(defun %client-session-output (queue &optional (output-fd 1))
  (%client-drop-pending-rendered-output queue)
  (loop while (%client-output-queue-head queue) do
    (select-fds nil +poll-timeout-us+ :write-fds (list output-fd))
    (%client-write-output-ready queue output-fd))
  (%client-enqueue-output
   queue
   (cl-codec-kit:string-to-octets
    (format nil "~C[?1004l~C[?2004l~C[?1049l~%" #\Escape #\Escape #\Escape)
    :encoding :utf-8))
  (loop while (%client-output-queue-head queue) do
    (select-fds nil +poll-timeout-us+ :write-fds (list output-fd))
    (%client-write-output-ready queue output-fd)))
(defun %run-attach-session (socket server-socket-fd target output-queue &optional (input-fd 0) (output-fd 1))
  "Run the client relay with one incremental reader and writer on SOCKET."
  (let ((reader (make-frame-reader))
        (writer (make-frame-writer))
        (outbound-front
          (list (msg-attach *term-rows* *term-cols*
                            (%client-terminal-identity))
                (msg-command :attach-target nil
                             (list (or target "")
                                   (%client-working-directory)))))
        (outbound-back nil)
        (stdin-open-p t)
        (reservation nil)
        (pending-event nil)
        (parting nil)
        (done nil))
    (handler-case
        (loop until done do
          (when *resize-pending*
            (setf *resize-pending* nil)
            (multiple-value-setq (*term-rows* *term-cols*) (terminal-size))
            (push (msg-resize *term-rows* *term-cols*) outbound-back))
          (when pending-event
            (unless reservation
              (let ((needed (+ (length (second pending-event)) (length +client-sync-begin+) (length +client-sync-end+))))
                (when (%client-reserve-output output-queue needed)
                  (setf reservation needed))))
            (when reservation
              (multiple-value-bind (disposition text)
                  (%client-output-server-frame
                   output-queue (first pending-event) (second pending-event)
                   reservation)
                (setf pending-event nil reservation nil)
                (when text (setf parting text))
                (when (eq disposition :exit) (return)))))
          (let ((payload-size (frame-reader-payload-size reader)))
            (when (and payload-size (null reservation))
              (let ((needed (+ payload-size (length +client-sync-begin+) (length +client-sync-end+))))
                (when (%client-reserve-output output-queue needed)
                  (setf reservation needed)))))
          (unless (frame-writer-pending-p writer)
            (when (null outbound-front)
              (setf outbound-front (nreverse outbound-back)
                    outbound-back nil))
            (when outbound-front
              (start-frame-write writer (pop outbound-front))))
          (let* ((read-fds
                   (append (when stdin-open-p (list input-fd))
                           (when (and (null pending-event)
                                      (or reservation
                                          (null (frame-reader-payload-size reader))))
                             (list server-socket-fd))))
                 (write-fds
                   (append (when (frame-writer-pending-p writer)
                             (list server-socket-fd))
                           (when (%client-output-queue-head output-queue)
                             (list output-fd)))))
            (multiple-value-bind (read-ready write-ready)
                (select-fds read-fds +poll-timeout-us+ :write-fds write-fds)
              (when (and stdin-open-p (member input-fd read-ready))
                (let ((buffer (make-array +pty-buf-size+
                                          :element-type '(unsigned-byte 8))))
                  (multiple-value-bind (count status) (%client-read-fd input-fd buffer)
                    (case status
                      (:data
                       (push (msg-key (if (= count (length buffer))
                                          buffer
                                          (subseq buffer 0 count)))
                             outbound-back))
                      (:eof
                       (setf stdin-open-p nil)
                       (push (msg-detach) outbound-back))
                      (t nil)))))
              (when (member server-socket-fd write-ready)
                (write-frame-ready writer socket))
              (when (member output-fd write-ready)
                (%client-write-output-ready output-queue output-fd))
              (when (and (member server-socket-fd read-ready)
                         (null pending-event))
                (multiple-value-bind (type payload status)
                    (read-frame-ready
                     reader socket
                     :max-bytes (if reservation 65536 +header-size+))
                  (case status
                    (:frame (setf pending-event (list type payload)))
                    (:eof (setf done t))
                    (t nil))))))) (peer-io-failure (condition)
        (format *error-output* "~&nerimux: connection lost: ~A~%" condition))) parting)
)
(defun run-client (name &key target)
  "Attach to the server, relay input and frames, then restore both terminal modes."
  (require :sb-posix)
  (let ((socket (connect-to (socket-path name))))
    (unwind-protect
         (let* ((server-socket-fd (socket-fd socket))
                (input-flags (%client-fd-flags 0))
                (output-flags (%client-fd-flags 1))
                (output-queue (%make-client-output-queue))
                (parting nil))
           (unwind-protect
                (progn
                  (%client-set-nonblocking 0)
                  (%client-set-nonblocking 1)
                  (multiple-value-setq (*term-rows* *term-cols*) (terminal-size))
                  (setf *resize-pending* nil)
                  (install-sigwinch-handler)
                  (enable-raw-mode! 0)
                  (unwind-protect
                       (setf parting
                             (progn
                               (%client-enqueue-output
                                output-queue
                                (cl-codec-kit:string-to-octets
                                 (format nil
                                         "~C[?1049h~C[?2004h~C[?1004h~C[2J~C[Hnerimux: connecting..."
                                         #\Escape #\Escape #\Escape #\Escape #\Escape)
                                 :encoding :utf-8))
                               (%run-attach-session socket server-socket-fd target
                                                    output-queue)))
                    (unwind-protect
                         (%client-session-output output-queue)
                      (disable-raw-mode! 0)))
                  (when parting
                    (format *error-output* "~&~A~%" parting)
                    (force-output *error-output*)))
             (unwind-protect
                  (%client-restore-fd-flags 0 input-flags)
               (%client-restore-fd-flags 1 output-flags))))
      (close-socket socket :abort t))))

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

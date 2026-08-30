(in-package #:nerimux/net)

;;;; Unix-domain socket primitives for client/server detach-attach.
;;;;
;;;; Thin wrappers over sb-bsd-sockets so the server/client loops (and tests)
;;;; speak in terms of make-listener / accept-connection / connect-to / a binary
;;;; socket-stream, rather than the raw contrib API.  Frame I/O over the stream
;;;; lives in nerimux/transport; message framing in nerimux/protocol.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets))

(defconstant +accept-timeout-seconds+ 5
  "Maximum seconds to block in accept-connection before returning NIL.
   Prevents the server accept loop from blocking forever on a client that
   opens a TCP connection but never sends any data.")

(defconstant +socket-stream-timeout-seconds+ 30
  "Timeout in seconds passed to socket-make-stream for read/write operations.
   Bounds the duration of individual read-sequence / write-sequence calls on a
   socket stream so a hung or slow peer does not block the server indefinitely.")

(defmacro %swallow-to-nil ((&rest condition-classes) &body body)
  "Run BODY; if it signals any of CONDITION-CLASSES, return NIL instead.
   Local to this file: both accept-connection (sb-ext:timeout on a bounded
   accept) and unix-socket-available-p (any error probing a throwaway bind)
   need 'reduce a blocking/failing syscall to a boolean-ish NIL', so this
   collapses the shared handler-case shape to one call site per use."
  `(handler-case (progn ,@body)
     ,@(mapcar (lambda (condition-class) `(,condition-class () nil))
               condition-classes)))

(defun make-listener (path &key (backlog 1))
  "Bind a Unix-domain stream socket at PATH and start listening (BACKLOG deep)."
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-bind socket path)
    (sb-bsd-sockets:socket-listen socket backlog)
    socket))

(defun accept-connection (listener)
  "Accept one connection from LISTENER within +accept-timeout-seconds+.
   Returns the connected socket, or NIL when the accept times out.
   Prevents the server accept loop from blocking forever on a client that
   connects at the TCP level but never sends a handshake."
  (%swallow-to-nil (sb-ext:timeout)
    (sb-ext:with-timeout +accept-timeout-seconds+
      (sb-bsd-sockets:socket-accept listener))))

(defconstant +connect-timeout-seconds+ 5
  "Maximum seconds to block in connect-to before signalling a timeout error.
   Prevents the client from hanging indefinitely when the server socket path
   exists but no process is accepting connections.")

(defun connect-to (path)
  "Connect a fresh Unix-domain stream socket to the listener at PATH.
   The connect attempt is bounded by +connect-timeout-seconds+; signals
   SB-EXT:TIMEOUT when the server does not accept within that window."
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-ext:with-timeout +connect-timeout-seconds+
      (sb-bsd-sockets:socket-connect socket path))
    socket))

(defun socket-stream (socket)
  "A bidirectional binary stream over SOCKET (element-type (unsigned-byte 8)).
   The stream is created with a timeout so individual read/write calls do not
   block indefinitely when the peer is hung."
  (sb-bsd-sockets:socket-make-stream socket
                                     :input t :output t
                                     :element-type '(unsigned-byte 8)
                                     :timeout +socket-stream-timeout-seconds+))

(defun socket-fd (socket)
  "The underlying file descriptor of SOCKET (for select-based multiplexing)."
  (sb-bsd-sockets:socket-file-descriptor socket))

(defun close-socket (socket &key abort)
  "Close SOCKET, ignoring errors (e.g. already closed by its stream).

   ABORT is forwarded to SB-BSD-SOCKETS:SOCKET-CLOSE, which forwards it to
   CL:CLOSE on the socket's cached stream when one has been made (see
   SOCKET-STREAM below) rather than closing the raw fd directly. With ABORT
   NIL (the default), CLOSE first tries to flush any output still buffered
   in that stream; a peer that already broke the pipe makes that flush fail
   with a second BROKEN-PIPE, and on SBCL that failure happens BEFORE the
   underlying UNIX-CLOSE, so the fd is never actually released even though
   this function swallows the condition and returns normally.  Pass ABORT T
   to close a socket whose peer may already be gone (e.g. tearing down a
   dropped client) — it skips the flush attempt entirely, so a broken peer
   cannot prevent this end's own fd from being freed."
  (handler-case (sb-bsd-sockets:socket-close socket :abort abort)
    (sb-bsd-sockets:socket-error () nil)))

(defun %make-probe-socket-path ()
  "Generate a unique throwaway socket path in the temp directory."
  (let ((directory (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))))
    (format nil "~A/nerimux-probe-~D-~D.sock"
            directory (get-universal-time) (random 1000000))))

(defun unix-socket-available-p ()
  "True when a Unix-domain socket can be bound in the temp directory.
   Probes by binding then removing a throwaway socket path; returns NIL when
   the environment forbids it (e.g. a restricted sandbox)."
  (let ((path (%make-probe-socket-path)))
    (%swallow-to-nil (sb-bsd-sockets:socket-error file-error)
      (let ((socket (make-listener path)))
        (close-socket socket)
        (delete-file path)
        t))))

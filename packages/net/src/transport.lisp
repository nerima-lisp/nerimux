(in-package #:nerimux/transport)
(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-bsd-sockets) (require :sb-posix))

(defconstant +read-frame-timeout-seconds+
  30
  "Maximum seconds to wait for a complete frame before aborting.
   Prevents indefinite blocking on a hung or slow peer.
   This budget is shared across both the header and payload read phases.")

(defconstant +send-frame-timeout-seconds+
  30
  "Maximum seconds to wait for write-sequence and finish-output to complete
   before aborting.  Mirrors +read-frame-timeout-seconds+ and applies even when
   the caller's stream has no timeout (e.g. nerimux/net:socket-stream).")

(defconstant +max-frame-payload-bytes+
  (* 64 1024 1024)
  "Maximum payload size (64 MiB) accepted by read-frame before rejecting.
   Prevents a malicious or buggy peer from triggering unbounded heap allocation.")

(defun send-frame (stream frame)
  "Write FRAME (an octet vector produced by the nerimux/protocol msg-* helpers)
   to binary STREAM and flush it, within +send-frame-timeout-seconds+.
   Signals SB-EXT:TIMEOUT when the peer is too slow to accept the write."
  (%validate-outgoing-frame frame)
  (sb-ext:with-timeout +send-frame-timeout-seconds+
                       (write-sequence frame stream)
                       (finish-output stream)))

(defun %read-exact (buffer stream start end)
  "Fill BUFFER[START..END) from STREAM; return the actual number of bytes read.
   A return value less than (- END START) indicates EOF or a short-read at the
   stream boundary.  This is a thin wrapper over READ-SEQUENCE rather than an
   inline call so that the two phases of READ-FRAME can each be named and tested
   independently: the header phase and the payload phase are distinct contracts."
  (read-sequence buffer stream :start start :end end))

(defun %payload-length-acceptable-p (payload-length)
  "Return true when PAYLOAD-LENGTH is a valid declared payload size.
   The contract: PAYLOAD-LENGTH must be a non-negative integer no greater than
   +max-frame-payload-bytes+.  This check is security-relevant: it prevents a
   malicious or buggy peer from causing unbounded heap growth by sending a frame
   header that declares an astronomically large payload length before any bytes
   of payload are read."
  (and (integerp payload-length)
       (<= 0 payload-length +max-frame-payload-bytes+)))

(defun %validate-outgoing-frame (frame)
  "Validate FRAME (an octet vector) before writing it to a stream.
   Three invariants are enforced:
     1. FRAME must be a vector at least +header-size+ bytes long.
     2. Payload length declared in the header must not exceed
        +max-frame-payload-bytes+.
     3. Total byte count must equal +header-size+ plus declared payload length
        (the frame is self-consistent: no trailing garbage, no truncation).
   Signals an error when any invariant is violated."
  (unless (and (vectorp frame) (>= (length frame) +header-size+))
    (error "Invalid frame: must be a vector of at least ~D bytes, got ~S"
           +header-size+
           frame))
  (let* ((payload-length (read-u32 frame +payload-length-offset+))
         (expected-total (+ +header-size+ payload-length)))
    (unless (%payload-length-acceptable-p payload-length)
      (error
       "Invalid frame: declared payload length ~D exceeds +max-frame-payload-bytes+ (~D)"
       payload-length
       +max-frame-payload-bytes+))
    (unless (= (length frame) expected-total)
      (error
       "Invalid frame: total length ~D does not match header+payload (~D + ~D = ~D)"
       (length frame)
       +header-size+
       payload-length
       expected-total))))

(defun %read-header-k (stream continuation)
  "Phase 1: read a 5-byte frame header from STREAM into a fresh adjustable buffer.
   On success, call CONTINUATION with the buffer and the decoded payload length.
   Returns NIL when the stream ends before a complete header is available."
  (let ((buffer
         (make-array +header-size+
                     :element-type
                     '(unsigned-byte 8)
                     :adjustable
                     t
                     :fill-pointer
                     +header-size+)))
    (when (= +header-size+ (%read-exact buffer stream 0 +header-size+))
      (let ((payload-length (read-u32 buffer +payload-length-offset+)))
        (when (%payload-length-acceptable-p payload-length)
          (funcall continuation buffer payload-length))))))

(defun %read-payload-k (buffer payload-length stream continuation)
  "Phase 2: grow BUFFER to fit PAYLOAD-LENGTH bytes, read the payload from STREAM
   directly into the tail, then call CONTINUATION with the completed buffer.
   Returns NIL when the stream ends before all payload bytes have arrived."
  (let ((total-length (+ +header-size+ payload-length)))
    (adjust-array buffer total-length :fill-pointer total-length)
    (when 
        (= total-length (%read-exact buffer stream +header-size+ total-length))
      (funcall continuation buffer))))

(defun read-frame (stream)
  "Read one complete frame from binary STREAM.
   Returns (values TYPE PAYLOAD), or NIL at end of stream (peer closed,
   mid-frame EOF, or timeout expiry after +read-frame-timeout-seconds+).
   Uses a two-phase CPS read into a single adjustable buffer: %read-header-k
   reads the header (Phase 1), %read-payload-k grows the buffer and reads the
   payload into the tail (Phase 2).  No intermediate header array is allocated
   and no REPLACE copy is needed.
   A single sb-ext:with-timeout wraps both phases so the total wall-clock
   budget is at most +read-frame-timeout-seconds+ seconds."
  (handler-case (sb-ext:with-timeout +read-frame-timeout-seconds+
                                     (%read-header-k stream
                                                     (lambda 
                                                         (buffer payload-length)
                                                       (%read-payload-k buffer
                                                                        payload-length
                                                                        stream
                                                                        (lambda 
                                                                            (complete-buffer)
                                                                          (multiple-value-bind (type
                                                                                                payload) 
                                                                              (decode-frame
                                                                               complete-buffer)
                                                                            (values
                                                                             type
                                                                             payload)))))))
    (sb-ext:timeout ()
      nil)))

(defmacro with-incoming-frame ((type-var payload-var stream) &rest rules)
  "Read one frame from STREAM, bind TYPE-VAR and PAYLOAD-VAR, then dispatch
   through the Prolog-like rule table RULES.  Each RULE is (condition &rest body).
   NIL type (EOF) must be handled by the caller if no rule matches.

   Prolog analogy:
     handle_frame(nil, _)           :- disconnect.
     handle_frame(msg_detach, _)    :- disconnect.
     handle_frame(msg_key, payload) :- process_keys(session, payload)."
  `(multiple-value-bind (,type-var ,payload-var) (read-frame ,stream)
     (cond
       ,@(mapcar
          (lambda (rule)
            (destructuring-bind (condition &rest body) rule
              `(,condition ,@body)))
          rules))))
(progn
  (defconstant +incremental-io-buffer-size+ 65536)

  (defstruct (frame-reader
              (:constructor %make-frame-reader
                  (&key buffer scratch offset frame-size failed-p eof-p)))
    buffer
    scratch
    (offset 0)
    frame-size
    failed-p
    eof-p)

  (defun %make-frame-reader-buffer ()
    (make-array +header-size+
                :element-type '(unsigned-byte 8)
                :adjustable t
                :fill-pointer +header-size+))

  (defun make-frame-reader ()
    "Create state for reading frames from one nonblocking socket."
    (%make-frame-reader
     :buffer (%make-frame-reader-buffer)
     :scratch (make-array +incremental-io-buffer-size+
                          :element-type '(unsigned-byte 8))
     :offset 0))

  (defun %socket-error-errno (condition)
    (sb-bsd-sockets::socket-error-errno condition))

  (defun %would-block-errno-p (errno)
    (or (= errno sb-posix:eagain)
        (= errno sb-posix:ewouldblock)))

  (defun %socket-receive (socket buffer length)
    (loop
      (handler-case
          (multiple-value-bind (received-buffer count address)
              (sb-bsd-sockets:socket-receive
               socket buffer length
               :dontwait t
               :element-type '(unsigned-byte 8))
            (declare (ignore received-buffer address))
            (return-from %socket-receive
              (if count
                  (values count :data)
                  (values nil :would-block))))
        (sb-bsd-sockets:socket-error (condition)
          (let ((errno (%socket-error-errno condition)))
            (cond
              ((= errno sb-posix:eintr))
              ((%would-block-errno-p errno)
               (return-from %socket-receive (values nil :would-block)))
              (t (error condition))))))))

  (defun %validate-ready-max-bytes (max-bytes)
    (unless (typep max-bytes '(integer 1 *))
      (error "MAX-BYTES must be a positive integer, got ~S" max-bytes))
    max-bytes))
(progn
  (defun %reader-set-payload-size (reader)
    (let ((payload-length
            (read-u32 (frame-reader-buffer reader)
                      +payload-length-offset+)))
      (unless (%payload-length-acceptable-p payload-length)
        (error
         "Invalid incremental frame: declared payload length ~D exceeds limit ~D"
         payload-length
         +max-frame-payload-bytes+))
      (let ((frame-size (+ +header-size+ payload-length)))
        (setf (frame-reader-frame-size reader) frame-size
              (frame-reader-buffer reader)
              (adjust-array (frame-reader-buffer reader)
                            frame-size
                            :fill-pointer frame-size)))))
  (defun %reader-reset-frame (reader)
    (setf (frame-reader-buffer reader) (%make-frame-reader-buffer)
          (frame-reader-offset reader) 0
          (frame-reader-frame-size reader) nil))
  (defun frame-reader-payload-size (reader)
    "Return the declared payload size after the reader has parsed a frame header."
    (check-type reader frame-reader)
    (let ((frame-size (frame-reader-frame-size reader)))
      (when frame-size
        (- frame-size +header-size+)))))
(defun read-frame-ready (reader socket &key (max-bytes 65536))
  "Return TYPE and PAYLOAD with :FRAME when one frame completes. Return NIL,
   NIL, and :PENDING when this call made progress but the frame is incomplete;
   return NIL, NIL, and :WOULD-BLOCK when it made no progress. :EOF indicates
   peer closure, including closure during a partial frame. MAX-BYTES limits all
   bytes received during this call."
  (%validate-ready-max-bytes max-bytes)
  (check-type reader frame-reader)
  (when (frame-reader-failed-p reader)
    (error "Cannot read with a failed frame reader"))
  (when (frame-reader-eof-p reader)
    (return-from read-frame-ready (values nil nil :eof)))
  (let ((budget max-bytes)
        (progress nil))
    (handler-case
        (loop
          (when (and (= (frame-reader-offset reader) +header-size+)
                     (null (frame-reader-frame-size reader)))
            (%reader-set-payload-size reader))
          (when (and (frame-reader-frame-size reader)
                     (= (frame-reader-offset reader)
                        (frame-reader-frame-size reader)))
            (multiple-value-bind (type payload)
                (decode-frame (frame-reader-buffer reader))
              (%reader-reset-frame reader)
              (return (values type payload :frame))))
          (when (zerop budget)
            (return (values nil nil :pending)))
          (let* ((target-size
                   (or (frame-reader-frame-size reader) +header-size+))
                 (request-size
                   (min budget
                        (length (frame-reader-scratch reader))
                        (- target-size (frame-reader-offset reader)))))
            (multiple-value-bind (count status)
                (%socket-receive socket
                                 (frame-reader-scratch reader)
                                 request-size)
              (cond
                ((eq status :would-block)
                 (return
                   (values nil nil (if progress :pending :would-block))))
                ((not (eq status :data))
                 (error "Invalid socket receive status ~S" status))
                ((not (and (integerp count)
                           (<= 0 count request-size)))
                 (error "Invalid socket receive byte count ~S" count))
                ((zerop count)
                 (setf (frame-reader-eof-p reader) t)
                 (return (values nil nil :eof)))
                (t
                 (replace (frame-reader-buffer reader)
                          (frame-reader-scratch reader)
                          :start1 (frame-reader-offset reader)
                          :end2 count)
                 (incf (frame-reader-offset reader) count)
                 (decf budget count)
                 (setf progress t))))))
      (error (condition)
        (setf (frame-reader-failed-p reader) t)
        (error condition)))))
(progn
  (defstruct (frame-writer
              (:constructor %make-frame-writer (&key scratch)))
    frame
    scratch
    (offset 0)
    failed-p)

  (defun make-frame-writer ()
    "Create single-owner state for writing frames to one nonblocking socket."
    (%make-frame-writer
     :scratch (make-array +incremental-io-buffer-size+
                          :element-type '(unsigned-byte 8))))

  (defun frame-writer-pending-p (writer)
    (check-type writer frame-writer)
    (not (null (frame-writer-frame writer))))

  (defun %socket-send (socket buffer length)
    (loop
      (handler-case
          (return-from %socket-send
            (values
             (sb-bsd-sockets:socket-send
              socket buffer length :dontwait t :nosignal t)
             :data))
        (sb-bsd-sockets:socket-error (condition)
          (let ((errno (%socket-error-errno condition)))
            (cond
              ((= errno sb-posix:eintr))
              ((%would-block-errno-p errno)
               (return-from %socket-send (values nil :would-block)))
              (t (error condition))))))))

  (defun %validate-incremental-frame (frame)
    (unless (typep frame '(vector (unsigned-byte 8)))
      (error "Invalid incremental frame: expected an octet vector, got ~S"
             (type-of frame)))
    (%validate-outgoing-frame frame))

  (defun start-frame-write (writer frame)
    "Queue FRAME if WRITER is idle; keep FRAME unchanged until it completes."
    (check-type writer frame-writer)
    (when (frame-writer-failed-p writer)
      (error "Cannot queue a frame on a failed writer"))
    (when (frame-writer-pending-p writer)
      (error "Cannot queue a frame while another frame is pending"))
    (%validate-incremental-frame frame)
    (setf (frame-writer-frame writer) frame
          (frame-writer-offset writer) 0)
    writer)

  (defun write-frame-ready (writer socket &key (max-bytes 65536))
    "Return :COMPLETE when the queued frame finishes or WRITER is idle, :PENDING
     when this call sent bytes but the frame remains incomplete, or :WOULD-BLOCK
     when this call sent no bytes. MAX-BYTES bounds bytes sent per call."
    (%validate-ready-max-bytes max-bytes)
    (check-type writer frame-writer)
    (when (frame-writer-failed-p writer)
      (error "Cannot write with a failed frame writer"))
    (let ((budget max-bytes)
          (progress 0))
      (handler-case
          (loop
           (let ((frame (frame-writer-frame writer)))
             (unless frame
               (return (values :complete progress)))
             (let* ((remaining
                     (- (length frame) (frame-writer-offset writer)))
                    (request-size
                     (min budget
                          (length (frame-writer-scratch writer))
                          remaining)))
               (when (zerop request-size)
                 (setf (frame-writer-frame writer) nil
                       (frame-writer-offset writer) 0)
                 (return (values :complete progress)))
               (replace (frame-writer-scratch writer) frame
                        :start1 0
                        :start2 (frame-writer-offset writer)
                        :end2 (+ (frame-writer-offset writer)
                                 request-size))
               (multiple-value-bind (count status)
                   (%socket-send socket
                                 (frame-writer-scratch writer)
                                 request-size)
                 (cond
                  ((eq status :would-block)
                   (return
                    (values (if (plusp progress) :pending :would-block)
                            progress)))
                  ((not (eq status :data))
                   (error "Invalid socket send status ~S" status))
                  ((not (and (integerp count)
                             (< 0 count)
                             (<= count request-size)))
                   (error "Invalid socket send byte count ~S" count))
                  (t
                   (incf (frame-writer-offset writer) count)
                   (incf progress count)
                   (decf budget count)
                   (when (= (frame-writer-offset writer) (length frame))
                     (setf (frame-writer-frame writer) nil
                           (frame-writer-offset writer) 0)
                     (return (values :complete progress)))
                   (when (zerop budget)
                     (return (values :pending progress)))))))))
        (error (condition)
               (setf (frame-writer-failed-p writer) t)
               (error condition))))))

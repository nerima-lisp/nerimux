(defpackage #:nerimux/protocol
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the client/server wire format, as a pure codec.  Encodes
    and decodes the frames a detached client exchanges with the server, keystrokes
    and resizes upstream, rendered frames downstream, plus the delimiter-separated
    command payload.  Deliberately holds no sockets and no global state, so the
    format is unit-testable without a server; the I/O sits in nerimux/transport.")
  (:export
   #:+msg-attach+ #:+msg-key+ #:+msg-resize+ #:+msg-detach+ #:+msg-frame+ #:+msg-bye+
   #:+msg-command+ #:+msg-reply+ #:+msg-notification+
   #:+header-size+
   #:+payload-length-offset+
   #:+cols-offset-in-size-payload+
   #:encode-frame #:decode-frame
   #:msg-attach #:msg-key #:msg-resize #:msg-detach #:msg-frame #:msg-bye
   #:msg-command #:msg-reply #:msg-notification
   #:encode-attach-terminal-environment #:decode-attach
   #:+field-delimiter+
   #:encode-command-payload #:decode-command-payload #:target-field-p
   #:split-on-nul-bytes #:command-name-to-string
   #:assemble-command-fields #:encode-fields-to-buffer
   #:decode-size #:decode-text #:to-octets
   #:u16-octets #:u32-octets #:u16-octets-pair #:read-u16 #:read-u32))

(defpackage #:nerimux/transport
  (:use #:cl)
  (:import-from #:nerimux/protocol
                #:+header-size+
                #:+payload-length-offset+
                #:read-u32
                #:decode-frame)
  (:documentation
   "INFRASTRUCTURE layer: READ-FRAME and SEND-FRAME provide synchronous binary-stream I/O. The
    incremental API accepts socket objects directly, uses nonblocking socket
    calls, and bypasses stream buffering. READ-FRAME-READY returns :FRAME,
    :PENDING (progress with an incomplete frame), :WOULD-BLOCK (no progress), or
    :EOF; MAX-BYTES limits bytes transferred per call. WRITE-FRAME-READY returns
    :COMPLETE, :PENDING (progress with an incomplete frame), or :WOULD-BLOCK.
    Keep one I/O path per socket: do not mix incremental operations with the
    stream API. The caller owns the socket, leaves queued frame bytes unchanged
    until completion, and closes the socket after an I/O failure.")
  (:export
   #:send-frame
   #:read-frame
   #:with-incoming-frame
   #:frame-reader #:frame-reader-p #:make-frame-reader #:read-frame-ready
   #:frame-writer #:frame-writer-p #:make-frame-writer
   #:start-frame-write #:write-frame-ready
   #:frame-writer-pending-p #:frame-writer-offset #:frame-writer-failed-p))

(defpackage #:nerimux/net
            (:use #:cl)
            (:documentation
             "INFRASTRUCTURE layer: the Unix-domain socket underneath detach-attach.  Thin
    wrappers over sb-bsd-sockets so the server and client loops speak in terms of
    make-listener / accept-connection / connect-to and a binary stream rather than
    the raw contrib API, and so tests can ask whether the transport is available at
    all before exercising it.")
            (:export #:make-listener
                     #:accept-connection
                     #:connect-to
                     #:socket-stream
                     #:socket-fd
                     #:close-socket
                     #:unix-socket-available-p))

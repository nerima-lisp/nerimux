;;; ── Client/server wire protocol ──────────────────────────────────────────

(defpackage #:nerimux/protocol
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the client/server wire format, as a pure codec.  Encodes
    and decodes the frames a detached client exchanges with the server — keystrokes
    and resizes upstream, rendered frames downstream — plus the delimiter-separated
    command payload.  Deliberately holds no sockets and no global state, so the
    format is unit-testable without a server; the I/O sits in nerimux/transport.")
  (:export
   ;; Message type tags + header size
   #:+msg-attach+ #:+msg-key+ #:+msg-resize+ #:+msg-detach+ #:+msg-frame+ #:+msg-bye+
   #:+msg-command+ #:+msg-reply+
   #:+header-size+
   ;; Frame layout constants
   #:+payload-length-offset+
   #:+cols-offset-in-size-payload+
   ;; Frame codec
   #:encode-frame #:decode-frame
   ;; Typed message constructors
   #:msg-attach #:msg-key #:msg-resize #:msg-detach #:msg-frame #:msg-bye
   #:msg-command #:msg-reply
   ;; Command message codec (protocol-command.lisp, same package)
   #:+field-delimiter+
   #:encode-command-payload #:decode-command-payload #:target-field-p
   ;; Command payload helpers — exported as stable API so tests use single-colon access
   #:split-on-nul-bytes #:command-name-to-string
   #:assemble-command-fields #:encode-fields-to-buffer
   ;; Payload decoders + octet helpers
   #:decode-size #:decode-text #:to-octets
   ;; Integer codec helpers (exported so tests can use single-colon access)
   #:u16-octets #:u32-octets #:u16-octets-pair #:read-u16 #:read-u32))

;;; ── Client/server stream transport ───────────────────────────────────────

(defpackage #:nerimux/transport
  (:use #:cl)
  ;; Four names out of the codec's forty: the header size and payload-length
  ;; offset needed to know how much to read, the length decoder, and DECODE-FRAME.
  ;; Everything else in nerimux/protocol is for packet authors, not for the pipe.
  (:import-from #:nerimux/protocol
                #:+header-size+
                #:+payload-length-offset+
                #:read-u32
                #:decode-frame)
  (:documentation
   "INFRASTRUCTURE layer: the impure shell around the nerimux/protocol codec.  Moves
    whole frames across any binary stream — a socket stream in production, a
    temp-file stream in tests — under a wall-clock budget that keeps a hung peer
    from blocking a reader forever.  Does no framing of its own.")
  (:export
   #:send-frame            ; (stream octets)          — write one frame + flush
   #:read-frame            ; (stream) → (values type payload) or NIL at EOF
   #:with-incoming-frame)) ; macro — read + Prolog-dispatch one frame from a stream

(defpackage #:nerimux/net
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the Unix-domain socket underneath detach-attach.  Thin
    wrappers over sb-bsd-sockets so the server and client loops speak in terms of
    make-listener / accept-connection / connect-to and a binary stream rather than
    the raw contrib API, and so tests can ask whether the transport is available at
    all before exercising it.")
  (:export
   #:make-listener #:accept-connection #:connect-to
   #:socket-stream #:socket-fd #:close-socket
   #:unix-socket-available-p))

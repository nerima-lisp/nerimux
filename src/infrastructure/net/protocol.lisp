(in-package #:nerimux/protocol)

;;;; Wire protocol for client/server detach-attach.
;;;;
;;;; A multiplexer server holds the sessions/PTYs; a thin client attaches over a
;;;; Unix socket, forwarding keystrokes and resizes and receiving rendered
;;;; frames.  This file is the pure, transport-agnostic frame codec — no sockets,
;;;; no global state — so it is fully unit-testable.  The socket transport and
;;;; the server/client loops build on top of it.
;;;;
;;;; +msg-command+ payload codec lives in protocol-command.lisp (same package).
;;;;
;;;; Each frame on the wire is:
;;;;
;;;;     [TYPE u8] [LENGTH u32 big-endian] [PAYLOAD ... LENGTH bytes]
;;;;
;;;; encode-* return fresh octet vectors; decode-frame parses ONE frame from a
;;;; buffer and reports how many bytes it consumed, or NIL when the buffer does
;;;; not yet hold a complete frame (so a streaming reader can wait for more).

;;; ── Message type tags ───────────────────────────────────────────────────────

(defconstant +msg-attach+  1 "client→server: attach; payload = rows,cols (u16,u16)")
(defconstant +msg-key+     2 "client→server: raw input bytes for the active pane")
(defconstant +msg-resize+  3 "client→server: terminal resized; payload = rows,cols")
(defconstant +msg-detach+  4 "client→server: detach (empty payload)")
(defconstant +msg-frame+   5 "server→client: a rendered frame (UTF-8 payload)")
(defconstant +msg-bye+     6 "server→client: server is closing (empty payload)")
(defconstant +msg-command+ 7
  "client→server: a named command with optional -t target; payload =
   NUL-delimited [target NUL] command-name NUL [args...]")
(defconstant +msg-reply+   8
  "server→client: a forwarded command's text output (UTF-8 payload), for the
   CLI command client (e.g. display-message -p).")

(defconstant +header-size+ 5 "1 type byte + 4 length bytes.")

;;; ── Frame layout constants ───────────────────────────────────────────────────

(defconstant +payload-length-offset+ 1
  "Byte offset of the u32-big-endian payload-length field inside a frame header.")

(defconstant +cols-offset-in-size-payload+ 2
  "Byte offset of the cols u16 within a rows,cols size payload.")

;;; ── Octet helpers (data) ────────────────────────────────────────────────────
;;;
;;; define-uint-codec is a Prolog-like macro: each spec (encoder-name
;;; decoder-name bits doc) is a fact that generates a paired big-endian encoder
;;; and decoder defun.  The byte-extraction and shift forms are derived
;;; mechanically from the bit-width at macro-expansion time.

(defmacro define-uint-codec (&rest specs)
  "Build paired big-endian integer encoder and decoder functions from a
   declarative table.  Each SPEC is (encoder-name decoder-name bits docstring)."
  `(progn
     ,@(mapcar
        (lambda (spec)
          (destructuring-bind (encoder-name decoder-name bits docstring) spec
            (let ((bytes (/ bits 8)))
              `(progn
                 (defun ,encoder-name (n)
                   ,(format nil "~A — encoder: N (0..~D) as ~D big-endian octet~:P."
                            docstring (1- (expt 2 bits)) bytes)
                   (vector ,@(loop for shift from (- bits 8) downto 0 by 8
                                   collect `(ldb (byte 8 ,shift) n))))
                 (defun ,decoder-name (buffer start)
                   ,(format nil "~A — decoder: big-endian ~D-bit value from BUFFER at START."
                            docstring bits)
                   (logior ,@(loop for i from 0 below bytes
                                   for shift from (- bits 8) downto 0 by 8
                                   collect (if (zerop shift)
                                               `(aref buffer (+ start ,i))
                                               `(ash (aref buffer (+ start ,i)) ,shift)))))))))
        specs)))

(define-uint-codec
  (u16-octets read-u16 16 "Big-endian unsigned 16-bit integer codec")
  (u32-octets read-u32 32 "Big-endian unsigned 32-bit integer codec"))

(defun u16-octets-pair (a b)
  "A,B (each 0..65535) as four big-endian octets (two u16s)."
  (concatenate '(simple-array (unsigned-byte 8) (*))
               (u16-octets a) (u16-octets b)))

(defun to-octets (sequence)
  "Coerce SEQUENCE of (unsigned-byte 8) into a simple octet vector."
  (coerce sequence '(simple-array (unsigned-byte 8) (*))))

;;; ── Frame codec (logic) ─────────────────────────────────────────────────────

(defun encode-frame (type payload)
  "Encode one frame of TYPE carrying PAYLOAD into a fresh octet vector:
   [TYPE][LENGTH u32-be][PAYLOAD].  The vector is assembled declaratively
   via CONCATENATE — no mutable setf/replace calls."
  (let* ((payload-length (length payload))
         (length-bytes   (u32-octets payload-length))
         (payload-vector (to-octets payload)))
    (concatenate '(simple-array (unsigned-byte 8) (*))
                 (vector type) length-bytes payload-vector)))

(defun decode-frame (buffer &optional (start 0) (end (length buffer)))
  "Parse one frame from BUFFER[START..END).
   Returns (values TYPE PAYLOAD NEXT-INDEX) where NEXT-INDEX is the offset just
   past the frame, or (values NIL NIL START) when BUFFER does not yet contain a
   complete frame (header incomplete, or payload not fully arrived)."
  (if (< (- end start) +header-size+)
      (values nil nil start)
      (let* ((type           (aref buffer start))
             (payload-length (read-u32 buffer (+ start +payload-length-offset+)))
             (payload-start  (+ start +header-size+))
             (next           (+ payload-start payload-length)))
        (if (> next end)
            (values nil nil start)                 ; payload not fully arrived
            (values type
                    (subseq buffer payload-start next)
                    next)))))

;;; ── Wire message definition macro ────────────────────────────────────────────

(defmacro define-wire-messages (&rest specs)
  "Build typed frame constructor functions from a declarative table.
   Each SPEC is (name type-constant lambda-list payload-expr docstring).
   Generates one DEFUN per entry: (name lambda-list) → (encode-frame type payload)."
  `(progn
     ,@(mapcar
        (lambda (spec)
          (destructuring-bind (name type-const lambda-list payload-expr docstring) spec
            `(defun ,name ,lambda-list
               ,docstring
               (encode-frame ,type-const ,payload-expr))))
        specs)))

;;; ── Typed message constructors (data) ────────────────────────────────────────

(define-wire-messages
  (msg-key     +msg-key+     (octets)     (to-octets octets)
   "client→server frame carrying raw input OCTETS for the active pane.")
  (msg-resize  +msg-resize+  (rows cols)  (u16-octets-pair rows cols)
   "client→server frame announcing a new terminal size.")
  (msg-detach  +msg-detach+  ()           #()
   "client→server detach frame.")
  (msg-frame   +msg-frame+   (string)     (cl-codec-kit:string-to-octets string :encoding :utf-8)
   "server→client frame carrying a rendered screen STRING (UTF-8 encoded).")
  (msg-bye     +msg-bye+     ()           #()
   "server→client frame announcing the server is closing.")
  (msg-reply   +msg-reply+   (string)     (cl-codec-kit:string-to-octets string :encoding :utf-8)
   "server→client frame carrying a forwarded command's text output (UTF-8)."))

;;; ── Typed command message constructor ────────────────────────────────────────

(defun msg-attach (rows cols)
  "Build a +msg-attach+ frame carrying the initial terminal size.
   Payload is [rows u16][cols u16]."
  (encode-frame +msg-attach+ (u16-octets-pair rows cols)))

(defun msg-command (command-name target args)
  "Build a +msg-command+ frame.
   COMMAND-NAME is a keyword or string.  TARGET is a target string or NIL.
   ARGS is a list of argument strings or NIL."
  (encode-frame +msg-command+
                (encode-command-payload command-name :target target :args args)))

;;; ── Payload decoders (logic) ────────────────────────────────────────────────

(defun decode-size (payload)
  "Decode a rows,cols payload (u16,u16) into (values ROWS COLS)."
  (values (read-u16 payload 0) (read-u16 payload +cols-offset-in-size-payload+)))

(defun decode-text (payload)
  "Decode a UTF-8 frame PAYLOAD into a string, LENIENTLY: malformed sequences
   become U+FFFD instead of signalling.

   This is deliberately the opposite policy from SPLIT-ON-NUL-BYTES in
   protocol-command.lisp, which decodes strictly.  The two differ because the
   payloads differ in kind.  DECODE-TEXT is only ever applied to *display* text
   — +msg-frame+ rendered screen content — which is written to stdout and never
   re-parsed, interned, or dispatched on.  A command payload, by contrast, is
   interned and executed, so there a repaired string would be a guess with
   consequences.

   There is exactly one caller today: CLIENT.LISP's %DECODE-SERVER-FRAME, which
   classifies on the frame TYPE alone, and %RECEIVE-SERVER-FRAME, which only
   WRITE-STRINGs the text it returns.  Neither inspects the decoded string, so
   the lenient policy has no behavioural edge case to state.  It used to: the
   +msg-reply+ reader in client-command.lisp branched on (PLUSP (LENGTH TEXT))
   and on a trailing newline, which a fully-malformed payload could perturb by
   one synthesised TERPRI.  That reader went with the CLI command client, and
   nothing sends +msg-reply+ any more.

   Leniency also matters because the caller establishes no handler: signalling
   here would unwind the client's event loop and kill the user's attached
   terminal mid-render over a single bad byte.  The replacement character is
   passed explicitly rather than relying on the encoding's own default, matching
   PARSER-OSC-DISPATCH.LISP and SAFE-CODE-CHAR."
  (cl-codec-kit:octets-to-string (to-octets payload)
                                 :encoding :utf-8
                                 :errorp nil
                                 :replacement #\REPLACEMENT_CHARACTER))

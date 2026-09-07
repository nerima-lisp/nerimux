(in-package #:nerimux/protocol)

(defmacro define-uint-codec (&rest specs)
  "Build paired big-endian integer encoder and decoder functions.

SPECS are declarative codec definitions of the form
  (ENCODER DECODER BITS DOCSTRING).
The declaration is checked while the macro is expanded so a malformed wire
schema cannot silently generate a partial or non-byte-aligned codec."
  (labels ((expand-spec (spec)
             (destructuring-bind (encoder-name decoder-name bits docstring) spec
               (unless (and (symbolp encoder-name) (symbolp decoder-name))
                 (error "Codec names must be symbols: ~S" spec))
               (unless (and (integerp bits) (plusp bits) (zerop (mod bits 8)))
                 (error "Codec width must be a positive multiple of 8: ~S" spec))
               (unless (stringp docstring)
                 (error "Codec documentation must be a string: ~S" spec))
               (let ((bytes (/ bits 8)))
                 `(progn
                    (defun ,encoder-name (n)
                      ,(format nil "~A — ~D big-endian octets." docstring bytes)
                      (vector
                       ,@(loop for shift from (- bits 8) downto 0 by 8
                               collect `(ldb (byte 8 ,shift) n))))
                    (defun ,decoder-name (buffer start)
                      ,(format nil
                               "~A — big-endian ~D-bit value."
                               docstring
                               bits)
                      (logior
                       ,@(loop for i from 0 below bytes
                               for shift from (- bits 8) downto 0 by 8
                               collect (if (zerop shift)
                                           `(aref buffer (+ start ,i))
                                           `(ash (aref buffer (+ start ,i))
                                                 ,shift))))))))))
    `(progn
       ,@(mapcar #'expand-spec specs))))

(define-uint-codec (u16-octets read-u16 16 "Unsigned 16-bit integer codec")
                   (u32-octets read-u32 32 "Unsigned 32-bit integer codec"))

(defun u16-octets-pair (a b)
  "A,B (each 0..65535) as four big-endian octets (two u16s)."
  (concatenate '(simple-array (unsigned-byte 8) (*))
               (u16-octets a)
               (u16-octets b)))

(defun to-octets (sequence)
  "Coerce SEQUENCE of (unsigned-byte 8) into a simple octet vector."
  (coerce sequence '(simple-array (unsigned-byte 8) (*))))

(defun encode-frame (type payload)
  "Encode one frame of TYPE carrying PAYLOAD into a fresh octet vector:
   [TYPE][LENGTH u32-be][PAYLOAD].  The vector is assembled declaratively
   via CONCATENATE — no mutable setf/replace calls."
  (let* ((payload-length (length payload))
         (length-bytes (u32-octets payload-length))
         (payload-vector (to-octets payload)))
    (concatenate '(simple-array (unsigned-byte 8) (*))
                 (vector type)
                 length-bytes
                 payload-vector)))

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

(define-wire-messages
 (msg-key +msg-key+
          (octets)
          (to-octets octets)
          "client→server frame carrying raw input OCTETS for the active pane.")
 (msg-resize +msg-resize+
             (rows cols)
             (u16-octets-pair rows cols)
             "client→server frame announcing a new terminal size.")
 (msg-detach +msg-detach+ () #() "client→server detach frame.")
 (msg-frame +msg-frame+
            (string)
            (cl-codec-kit:string-to-octets string :encoding :utf-8)
            "server→client frame carrying a rendered screen STRING (UTF-8 encoded).")
 (msg-bye +msg-bye+
          ()
          #()
          "server→client frame announcing the server is closing.")
 (msg-reply +msg-reply+
            (string)
            (cl-codec-kit:string-to-octets string :encoding :utf-8)
            "server→client frame carrying a forwarded command's text output (UTF-8)."))

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

   Leniency also matters because the caller establishes no handler: signalling
   here would unwind the client's event loop and kill the user's attached
   terminal mid-render over a single bad byte.  The replacement character is
   passed explicitly rather than relying on the encoding's own default, matching
   PARSER-OSC-DISPATCH.LISP and SAFE-CODE-CHAR."
  (cl-codec-kit:octets-to-string (to-octets payload)
                                 :encoding
                                 :utf-8
                                 :errorp
                                 nil
                                 :replacement
                                 #\REPLACEMENT_CHARACTER))

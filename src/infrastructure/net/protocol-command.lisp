(in-package #:nerimux/protocol)

(defconstant +msg-attach+  1 "client→server: attach; payload = rows,cols (u16,u16)")
(defconstant +msg-key+     2 "client→server: raw input bytes for the active pane")
(defconstant +msg-resize+  3 "client→server: terminal resized; payload = rows,cols")
(defconstant +msg-detach+  4 "client→server: detach (empty payload)")
(defconstant +msg-frame+   5 "server→client: a rendered frame (UTF-8 payload)")
(defconstant +msg-bye+     6 "server→client: server is closing (empty payload)")
(defconstant +msg-command+ 7 "client→server: a named command")
(defconstant +msg-reply+   8 "server→client: a forwarded command's text output")
(defconstant +header-size+ 5 "1 type byte + 4 length bytes.")
(defconstant +payload-length-offset+ 1 "Byte offset of the u32 payload length.")
(defconstant +cols-offset-in-size-payload+ 2 "Byte offset of cols in a size payload.")

(defmacro define-wire-messages (&rest specs)
  "Build typed frame constructor functions from a declarative table."
  `(progn
     ,@(mapcar
        (lambda (spec)
          (destructuring-bind (name type-const lambda-list payload-expr docstring) spec
            `(defun ,name ,lambda-list
               ,docstring
               (encode-frame ,type-const ,payload-expr))))
        specs)))

;;;; +msg-command+ payload codec — NUL-delimited field encoding/decoding.
;;;;
;;;; This file is the pure, transport-agnostic codec for the command message
;;;; type.  It lives in the same package as protocol.lisp so all codec
;;;; primitives are co-located in nerimux/protocol.
;;;;
;;;; Payload format: NUL-delimited fields.
;;;;   [target NUL] command-keyword-name NUL [arg NUL ...]
;;;; When target is NIL the target field is omitted entirely.
;;;; The command keyword name is encoded without the leading colon.

(defconstant +field-delimiter+ 0
  "ASCII NUL byte used to separate fields in a +msg-command+ payload.
   Every field in the NUL-delimited encoding is terminated by this byte.")

;;; ── Target-sigil detection macro ─────────────────────────────────────────────
;;;
;;; define-target-sigils is a declarative table that drives the target-field-p
;;; predicate.  Each rule describes one detection policy:
;;;   (first-char CHAR)     — the field starts with CHAR (e.g. '$' for sessions)
;;;   (contains-char CHAR)  — the field contains CHAR anywhere (e.g. ':' or '.')
;;; Adding a new sigil never requires touching the function body.

(defmacro define-target-sigils (&rest rules)
  "Generate TARGET-FIELD-P from a declarative sigil/substring table.
   Each RULE is either (first-char CHAR) or (contains-char CHAR).
   Produces a DEFUN whose body is a flat OR over all rule tests."
  `(defun target-field-p (field)
     "Return true when FIELD looks like a target selector rather than a command name.
   A field is a target when it starts with '$' (session sigil), contains ':'
   (session:window syntax), or contains '.' (window.pane syntax).
   This predicate is the sole policy point for target detection; keeping it
   separate from the NUL-field-splitting logic ensures that command names
   containing these characters are never misidentified."
     (and (plusp (length field))
          (or ,@(mapcar (lambda (rule)
                          (destructuring-bind (kind char) rule
                            (ecase kind
                              (first-char  `(char= (char field 0) ,char))
                              (contains-char `(find ,char field)))))
                        rules)))))

(define-target-sigils
  (first-char   #\$)
  (contains-char #\:)
  (contains-char #\.))

(defun command-name-to-string (command-name)
  "Convert COMMAND-NAME (keyword or string) to a lowercase string for wire encoding."
  (if (keywordp command-name)
      (string-downcase (symbol-name command-name))
      command-name))

(defun assemble-command-fields (name-str target args)
  "Build the ordered list of NUL-delimited field strings for a command payload.
   TARGET is prepended when non-NIL; ARGS are appended after NAME-STR."
  (append (when target (list target))
          (list name-str)
          args))

(defun encode-fields-to-buffer (field-octets)
  "Pack FIELD-OCTETS (a list of octet vectors) into a fresh buffer using
   CONCATENATE (no mutable writes).  Each field is followed by a
   +field-delimiter+ (NUL) byte; the total length equals the sum of all
   field lengths plus one delimiter per field."
  (let* ((field-count (length field-octets))
         (delimiters  (make-list field-count :initial-element (vector +field-delimiter+))))
    (apply #'concatenate
           '(simple-array (unsigned-byte 8) (*))
           (mapcan #'list field-octets delimiters))))

(defun encode-command-payload (command-name &key target args)
  "Encode a command message payload.
   COMMAND-NAME is a keyword or string naming the command.
   TARGET is an optional -t target string (NIL = current session).
   ARGS is an optional list of argument strings.
   Returns a fresh octet vector of NUL-delimited UTF-8 fields."
  (let* ((name-str      (command-name-to-string command-name))
         (field-strings (assemble-command-fields name-str target args))
         (field-octets  (mapcar (lambda (s)
                                  (cl-codec-kit:string-to-octets s :encoding :utf-8))
                                field-strings)))
    (encode-fields-to-buffer field-octets)))

;;; ── Why this decode is deliberately STRICT ──────────────────────────────────
;;;
;;; PARSER-OSC-DISPATCH.LISP decodes with :ERRORP NIL and U+FFFD, and that is
;;; correct THERE: an OSC payload is terminal *output* handed to the title /
;;; colour / clipboard handlers as opaque text, so one unrepresentable byte
;;; costs one mangled glyph and can change no decision.
;;;
;;; A +msg-command+ payload is the opposite — a *control* channel.  Field 0
;;; reaches TARGET-FIELD-P and then INTERN in DECODE-COMMAND-PAYLOAD below: it
;;; names a command the server will execute.  Substituting U+FFFD would guess at
;;; a byte the sender never wrote, turning a malformed command into a different
;;; well-formed one, and would widen the set of byte strings that reach INTERN
;;; from "valid UTF-8" to "anything at all".  Input on a command channel must
;;; fail closed rather than be repaired.
;;;
;;; Failing closed is safe here precisely because the error has a bounded
;;; per-client destination.  CL-CODEC-KIT:DECODE-ERROR propagates out through
;;; %HANDLE-MULTI-COMMAND-MESSAGE into the WITH-LOOP-SAFE-ERROR guard in
;;; %READ-AND-DISPATCH-CLIENT-MESSAGE (server-multi-loop.lisp), which turns it
;;; into the :DROP disposition: the sender is disconnected, while the server,
;;; the session, and every other attached client keep running.  That guard is
;;; load-bearing — it is the only thing standing between a strict decode here
;;; and a server-wide crash, and it has been accidentally disabled once before
;;; (see the macro-ordering note at the top of the core server-multi-dispatch.lisp).
;;; Both halves are pinned together in
;;; tests/unit/infrastructure/net/protocol-command-malformed-utf8-tests.lisp so
;;; neither the strictness nor the guard can be removed on its own.

(defun split-on-nul-bytes (octets)
  "Split OCTETS on NUL bytes and return a list of decoded UTF-8 strings.
   Each NUL-terminated region becomes one string; bytes after the final NUL
   (if any) are ignored.  Returns NIL for an empty or NUL-free input.
   Decodes STRICTLY (:ERRORP T, the default): malformed UTF-8 in a command
   payload signals CL-CODEC-KIT:DECODE-ERROR rather than yielding a repaired
   string.  See the commentary above for why this channel must not be lenient
   and where the resulting condition is caught."
  (loop with start = 0
        for i from 0 below (length octets)
        when (zerop (aref octets i))
          collect (cl-codec-kit:octets-to-string octets :start start :end i :encoding :utf-8)
          and do (setf start (1+ i))))

(defun decode-command-payload (payload)
  "Decode a +msg-command+ PAYLOAD into (values command target args).
   COMMAND is the keyword symbol for the command name when that name matches
   an existing symbol in the KEYWORD package, or the raw command-name string
   when no such keyword exists.  Every command name the dispatch tables
   recognize is written as a literal keyword in source, so it is already
   interned by the time this runs; an unrecognized name is therefore never
   turned into a freshly interned keyword (which would grow the KEYWORD
   package without bound under client-controlled input) -- it is passed
   through as a string instead.  %HANDLE-CLIENT-UI-COMMAND compares COMMAND
   with EQ against keywords, so a string never matches and is handled the
   same as an unrecognized command; %HANDLE-MULTI-COMMAND-MESSAGE still
   reports \"unknown command: ~A\" for it, since a string is truthy and
   prints fine, whereas NIL would fall through and silently drop the message.
   TARGET is a string or NIL when absent.
   ARGS is a list of argument strings (may be nil).
   The first NUL-delimited field is examined by TARGET-FIELD-P to determine
   whether it is a target or the command name; all remaining fields are args.
   Returns (values NIL NIL NIL) when the payload contains no NUL-terminated
   fields (empty or NUL-free input)."
  (let ((fields (split-on-nul-bytes (to-octets payload))))
    (cond
      ((null fields)
       (values nil nil nil))
      ((and (>= (length fields) 2)
            (target-field-p (first fields)))
       (values (or (find-symbol (string-upcase (second fields)) :keyword)
                   (second fields))
               (first fields)
               (cddr fields)))
      (t
       (values (or (find-symbol (string-upcase (first fields)) :keyword)
                   (first fields))
               nil
               (rest fields))))))

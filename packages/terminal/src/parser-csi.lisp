(in-package #:nerimux/terminal/parser)

(defconstant +csi-digit-low+
  #x30
  "Lowest decimal digit byte in a CSI sequence (ASCII '0').")

(defconstant +csi-digit-high+
  #x39
  "Highest decimal digit byte in a CSI sequence (ASCII '9').")

(defconstant +csi-semicolon+
  #x3B
  "CSI parameter separator ';'.")

(defconstant +csi-colon+
  #x3A
  "CSI sub-parameter separator ':' (ISO 8613-6).  Introduces colon-delimited
   sub-parameters within one parameter, e.g. SGR 4:3 (undercurl) or
   38:2::R:G:B (true-colour).  A parameter carrying colon sub-parameters is
   collected into a list (sub0 sub1 …) so apply-sgr can apply colon-form
   extended colour, rather than dropping everything after the leading value.")

(defconstant +csi-dec-marker+
  #x3F
  "DEC private-mode marker '?'.")

(defconstant +csi-sec-da+
  #x3E
  "Secondary DA marker '>'.")

(defconstant +csi-xtpoptitle-marker+
  #x3C
  "ECMA-48 private-parameter marker '<' (e.g. CSI < Ps t, XTPOPTITLE).")

(defconstant +csi-tertiary-da-marker+
  #x3D
  "ECMA-48 private-parameter marker '=' (e.g. CSI = c, tertiary DA / DA3).")

(defconstant +csi-intermed-low+
  #x20
  "Lowest CSI intermediate byte (SPACE).")

(defconstant +csi-intermed-high+
  #x2F
  "Highest CSI intermediate byte.")

(defconstant +csi-final-low+
  #x40
  "Lowest valid CSI final byte '@'.")

(defconstant +csi-final-high+
  #x7E
  "Highest valid CSI final byte '~'.")

(declaim (inline csi-final-byte-before-p csi-final-byte-p))

(defun csi-final-byte-before-p (byte)
  "Return T when BYTE precedes the CSI final-byte range (i.e. still a
   parameter, intermediate, or marker byte — the sequence is incomplete)."
  (< byte +csi-final-low+))

(defun csi-final-byte-p (byte)
  "Return T when BYTE falls within the CSI final-byte range
   (+csi-final-low+ to +csi-final-high+), i.e. it terminates the sequence."
  (<= +csi-final-low+ byte +csi-final-high+))

(defun %finish-param (param-accumulator subparams)
  "Combine a parameter's leading PARAM-ACCUMULATOR with its colon SUBPARAMS
   (already-flushed sub-values, in reverse order) into the finished parameter:
   a plain integer when no colon appeared, or a list (sub0 sub1 …) when it did.
   An absent leading value defaults to 0 (matching the semicolon-param rule)."
  (if subparams
      (nreverse (cons (or param-accumulator 0) subparams))
      (or param-accumulator 0)))

(defun %csi-dispatch-final-byte (screen byte
                                        intermed
                                        private
                                        params
                                        param-accumulator
                                        subparams)
  "Flush the trailing parameter (if any), reverse the collected PARAMS into
   final CSI dispatch order, and call EXECUTE-CSI with the assembled sequence.
   Called by make-csi-k's continuation once a final byte (0x40-0x7E) closes
   the sequence.  Always returns #'GROUND-STATE."
  (let ((all-params
         (nreverse
          (if (or param-accumulator subparams)
              (cons (%finish-param param-accumulator subparams) params)
              params))))
    (execute-csi screen (code-char byte) intermed private all-params))
  #'ground-state)

(defun make-csi-k (&optional (params '()) (param-accumulator nil) (intermed nil)
                             (private nil) (subparams nil))
  "Return a continuation that collects CSI parameters then dispatches.
   Handles the standard VT/ECMA-48 CSI parameter syntax:
     param bytes        +csi-digit-low+ to +csi-digit-high+  (digits 0-9)
     semicolons         +csi-semicolon+                       (parameter separator)
     marker bytes       +csi-dec-marker+ (#\\?) and +csi-sec-da+ (#\\>)
       These are VT convention 'private use' markers that set the intermed slot
       rather than the parameter accumulator.  They are NOT the same as true
       intermediate bytes (#x20-#x2F), even though both affect INTERMED.
     intermediate bytes +csi-intermed-low+ to +csi-intermed-high+  (e.g. SPACE)
       True intermediate bytes such as #x20 (SPACE) select a sub-table of the
       final-byte dispatch (e.g. DECSCUSR uses CSI N SP q).
     final byte         +csi-final-low+  to +csi-final-high+  (dispatch)"
  (lambda (screen byte)
    (declare (type screen screen) (type (unsigned-byte 8) byte))
    (cond
      ((and (>= byte +csi-digit-low+) (<= byte +csi-digit-high+))
       (make-csi-k params
                   (+ (* (or param-accumulator 0) 10) (- byte +csi-digit-low+))
                   intermed private subparams))
      ((= byte +csi-colon+)
       (make-csi-k params nil intermed private
                   (cons (or param-accumulator 0) subparams)))
      ((= byte +csi-semicolon+)
       (make-csi-k (cons (%finish-param param-accumulator subparams) params)
                   nil intermed private nil))
      ((= byte +csi-dec-marker+)
       (make-csi-k params param-accumulator intermed #\? subparams))
      ((= byte +csi-sec-da+)
       (make-csi-k params param-accumulator intermed #\> subparams))
      ((= byte +csi-xtpoptitle-marker+)
       (make-csi-k params param-accumulator intermed #\< subparams))
      ((= byte +csi-tertiary-da-marker+)
       (make-csi-k params param-accumulator intermed #\= subparams))
      ((and (>= byte +csi-intermed-low+) (<= byte +csi-intermed-high+))
       (make-csi-k params param-accumulator (code-char byte) private subparams))
      ((csi-final-byte-p byte)
       (%csi-dispatch-final-byte screen byte intermed private params
                                  param-accumulator subparams))
      (t #'ground-state))))

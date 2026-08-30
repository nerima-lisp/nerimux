(in-package #:nerimux/renderer)

;;;; Status bar layout helpers.
;;;;
;;;; This file holds the SGR-aware width math, justify strategies, and aligned
;;;; segment composition used by renderer-statusbar.lisp.

;;; ── SGR-aware length / truncation ────────────────────────────────────────────
;;;
;;; Status strings may embed CSI SGR sequences — both from theme styling and
;;; from inline #[fg=…] blocks (expanded below).  Those sequences are
;;; zero-width on screen, so gap math and width clamping must count VISIBLE
;;; cells, not raw characters.  %SGR-SEQUENCE-END / %VISIBLE-LENGTH /
;;; %VISIBLE-TRUNCATE moved to renderer-format.lisp so the workspace frame's
;;; styled rows (which load earlier) share the same math.

(defun %status-style-block-sgr (body base-sgr)
  "SGR escape string for one inline #[BODY] status block: always resets to
   BASE-SGR (reset + base attrs), regardless of BODY.
   Previously an empty / \"default\" / \"none\" BODY reset to BASE-SGR while
   any other BODY was parsed as a style string (e.g. \"fg=green,bold\")
   via %status-sgr-from-style, which R2.4 deleted along with the rest of the
   style-string parser.  A non-default/none/empty BODY can only occur in
   live data now (a window/session name that happens to contain literal
   \"#[...]\" text — status-left/-right/window-status-format are fixed
   templates that never embed one themselves, R2.3), so there is no longer a
   config-authored style for a non-trivial BODY to mean anything; BODY is
   accepted but ignored."
  (declare (ignore body))
  (format nil "~C[0;~Am" +esc+ base-sgr))

(defun %status-expand-style-blocks (str base-sgr)
  "Replace inline #[…] style blocks in STR with CSI SGR escape sequences.
   #[fg=green,bold] → ESC[1;32m ; #[default] → reset to BASE-SGR.  Returns STR
   unchanged when it contains no #[ block, so default/format paths are untouched."
  (if (search "#[" str)
      (with-output-to-string (out)
        (let ((i 0) (len (length str)))
          (loop while (< i len)
                do (if (and (char= (char str i) #\#)
                            (< (1+ i) len)
                            (char= (char str (1+ i)) #\[))
                       (let ((close (position #\] str :start (+ i 2))))
                         (if close
                             (progn
                               (write-string
                                (%status-style-block-sgr (subseq str (+ i 2) close) base-sgr)
                                out)
                               (setf i (1+ close)))
                             (progn (write-char (char str i) out) (incf i))))
                       (progn (write-char (char str i) out) (incf i))))))
      str))

;;; %status-format-or-default, %status-segment-limit, and
;;; %clamp-status-segment used to live here: the option-driven per-segment
;;; length cap ("status-left-length" et al.) that fed R6.5's predecessor
;;; status bar. R6.5 replaced that bar outright with a fixed 3-block layout
;;; whose own width handling is %COMPOSE-WORKSPACE-STATUS-LINE's progressive
;;; degradation (renderer-statusbar.lisp) rather than a per-segment cap, so
;;; nothing calls these any more; removed rather than left as dead code.

(defun %split-comma-attrs (body)
  "Split BODY on commas and preserve empty fields."
  (let ((parts nil)
        (start 0))
    (loop for pos = (position #\, body :start start)
          do (push (subseq body start pos) parts)
          if pos do (setf start (1+ pos))
          else do (return (nreverse parts)))))

;;; %justify-right / %justify-centre / %status-justify-line and
;;; %status-segment-style-sgr / %apply-segment-style used to live here: the
;;; left+right two-segment layout and per-segment SGR override for R6.5's
;;; predecessor status bar (session name + window list vs. the clock). R6.5's
;;; fixed 3-block layout has its own composer, %COMPOSE-WORKSPACE-STATUS-LINE
;;; (renderer-statusbar.lisp), so these are gone rather than left unreachable.

;;; ── #[align=…] regions + status-format[0] template path ─────────────────────
;;;
;;; A status line format can be a single string whose #[align=left|centre|right]
;;; blocks divide it into three regions positioned within the terminal width.  nerimux
;;; normally renders the bar procedurally (status-left + window-list + status-
;;; right); when status-format[0] is SET it instead expands that template and
;;; composes the regions here.  The procedural default path is unchanged.

(defun %split-align-attr (body)
  "Parse a #[BODY] block's comma-separated attrs.  Returns (values ALIGN REST):
   ALIGN is :left/:centre/:right when an align=… attr is present (else NIL), and
   REST is the remaining attrs re-joined by commas (NIL when none) so combined
   blocks like #[align=right,fg=red] keep their colour."
  (let ((align nil) (rest nil))
    (dolist (a (%split-comma-attrs body))
      (let ((at (string-trim " " a)))
        (cond
          ((member at '("align=left" "align=l")   :test #'string-equal) (setf align :left))
          ((member at '("align=centre" "align=center" "align=c") :test #'string-equal)
           (setf align :centre))
          ((member at '("align=right" "align=r")  :test #'string-equal) (setf align :right))
          ((plusp (length at)) (push at rest)))))
    (values align (when rest (format nil "~{~A~^,~}" (nreverse rest))))))

(defun %status-align-block-step (raw i buckets current)
  "Process one #[…] block starting at RAW[I] (RAW[I] is #\#, RAW[I+1] is #\[).
   Returns (values NEXT-I NEXT-CURRENT).  An align=… attr switches NEXT-CURRENT
   and swallows the marker; any other block (or an unterminated '#[') is copied
   verbatim into the CURRENT bucket."
  (let ((close (position #\] raw :start (+ i 2))))
    (if close
        (multiple-value-bind (align rest) (%split-align-attr (subseq raw (+ i 2) close))
          (if align
              (progn (when rest (format (getf buckets align) "#[~A]" rest))
                     (values (1+ close) align))
              (progn (write-string (subseq raw i (1+ close)) (getf buckets current))
                     (values (1+ close) current))))
        (progn (write-char (char raw i) (getf buckets current))
               (values (1+ i) current)))))

(defun %status-align-step (raw i buckets current)
  "Process RAW[I] and return (values NEXT-I NEXT-CURRENT).  Dispatches to
   %status-align-block-step on a #[…] marker; otherwise copies the character
   into the CURRENT bucket unchanged."
  (if (and (char= (char raw i) #\#) (< (1+ i) (length raw)) (char= (char raw (1+ i)) #\[))
      (%status-align-block-step raw i buckets current)
      (progn (write-char (char raw i) (getf buckets current))
             (values (1+ i) current))))

(defun %status-align-buckets (raw)
  "Split RAW (a status format) into (values LEFT CENTRE RIGHT) raw substrings by
   its #[align=…] markers.  Text before any marker is LEFT; a combined block's
   non-align attrs are re-emitted as a #[…] prefix so colour is preserved."
  (let ((buckets (list :left (make-string-output-stream)
                       :centre (make-string-output-stream)
                       :right  (make-string-output-stream)))
        (current :left) (i 0) (len (length raw)))
    (loop while (< i len)
          do (multiple-value-setq (i current) (%status-align-step raw i buckets current)))
    (values (get-output-stream-string (getf buckets :left))
            (get-output-stream-string (getf buckets :centre))
            (get-output-stream-string (getf buckets :right)))))

(defun %expand-segment-or-empty (raw base-sgr reset)
  "Expand inline #[…] style blocks in RAW then append RESET; returns \"\" when RAW is empty."
  (if (plusp (length raw))
      (concatenate 'string (%status-expand-style-blocks raw base-sgr) reset)
      ""))

(defun %status-pad-to (out current target)
  "Pad OUT with spaces until CURRENT reaches TARGET; return the new column."
  (when (> target current)
    (dotimes (_ (- target current)) (write-char #\Space out))
    (setf current target))
  current)

(defun %status-emit-segment (out current cols seg width pos)
  "Emit SEG at POS in a COLS-wide line, returning the updated column."
  (if (plusp width)
      (let ((current (%status-pad-to out current (max current pos))))
        (when (< current cols)
          (write-string seg out)
          (+ current width)))
      current))

(defun %compose-aligned-line (raw base-sgr cols)
  "Render a status format RAW with #[align=…] regions into a COLS-wide line:
   the left region starts at column 0, the right region ends at COLS, and the
   centre region is centred.  Regions carry their own #[…] colours (reset to
   BASE-SGR after each).  Overlapping content is truncated to COLS."
  (multiple-value-bind (lraw craw rraw) (%status-align-buckets raw)
    (let* ((reset (format nil "~C[~Am" +esc+ base-sgr))
           (l (%expand-segment-or-empty lraw base-sgr reset))
           (c (%expand-segment-or-empty craw base-sgr reset))
           (r (%expand-segment-or-empty rraw base-sgr reset))
           (lw (%visible-length l)) (cw (%visible-length c)) (rw (%visible-length r)))
      (%visible-truncate
       (with-output-to-string (out)
         (let ((col 0))
           (write-string l out)
           (incf col lw)
           (setf col (%status-emit-segment out col cols c cw (floor (- cols cw) 2)))
           (setf col (%status-emit-segment out col cols r rw (- cols rw)))
           (setf col (%status-pad-to out col cols))))
       cols))))

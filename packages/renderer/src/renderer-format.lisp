(in-package #:nerimux/renderer)

;;;; ANSI escape-code primitives — pure data layer.
;;;;
;;;; All functions here write escape sequences to a stream; they do not touch
;;;; any model or terminal state.
(defconstant +esc+
  #\Escape)

;;; ── Cursor positioning ──────────────────────────────────────────────────────
(defun move-to (stream row col)
  "ESC[row;colH — cursor absolute position, 1-based."
  (format stream "~C[~D;~DH" +esc+ (1+ row) (1+ col)))

;;; ── Colour SGR emission helpers (Prolog-like fact table) ────────────────────
;;;
;;; Color encoding (matches cell.fg / cell.bg in cell.lisp):
;;;   0-7   : standard ANSI                → SGR 30-37 / 40-47
;;;   8-15  : bright ANSI                  → SGR 90-97 / 100-107
;;;   16-255: 256-color palette            → SGR 38;5;N / 48;5;N
;;;   bit 24 set (#x1000000+): true-color  → SGR 38;2;R;G;B / 48;2;R;G;B
;;;
;;; emit_colour(fg/bg, 0-7)       :- standard_colour_code(fg/bg, n).
;;; emit_colour(fg/bg, 8-15)      :- bright_colour_code(fg/bg, n).
;;; emit_colour(fg/bg, 16-255)    :- palette_256(fg/bg, n).
;;; emit_colour(fg/bg, 0x1RRGGBB) :- true_colour(fg/bg, r, g, b).
;;; ── Terminal colour-capability downsampling (cl-tty-kit) ────────────────────
;;;
;;; A -2 flag ("force 256-colour") exists because not every outer terminal
;;; understands 24-bit SGR (38;2;R;G;B).  nerimux always emitted
;;; true-colour unconditionally; *color-downsample-fn*, set from -2 by
;;; %apply-global-cli-invocation (main-startup-flags.lisp), routes true-colour
;;; cell values through cl-tty-kit:rgb-to-256 before classification so -2
;;; sessions degrade gracefully instead of leaking raw 24-bit escapes.
(defvar *color-downsample-fn*
  nil
  "Optional function (packed-rgb-int) -> palette-index, applied to TRUE-COLOR
   values (bit 24 set) before %EMIT-FG/%EMIT-BG classify them.  NIL (the
   default) emits true-colour unchanged, so the hot per-cell path pays only a
   single NULL check in the common case.")

(defun %rgb-int-to-256 (n)
  "Downsample packed true-colour int N (bit 24 set; RGB in bits 16-0) to the
   nearest xterm 256-palette index via cl-tty-kit:rgb-to-256."
  (let ((rgb (logand n #xFFFFFF)))
    (cl-tty-kit:rgb-to-256 (ash rgb -16)
                           (logand (ash rgb -8) #xFF)
                           (logand rgb #xFF))))

(declaim (inline %maybe-downsample-color))

(defun %maybe-downsample-color (n)
  "Return N, or its *color-downsample-fn* projection when N is true-colour."
  (if (and *color-downsample-fn* (logbitp 24 n))
      (funcall *color-downsample-fn* n)
      n))

;;; %EMIT-FG and %EMIT-BG are inlined: render-pane calls render-cell-attrs up
;;; to ~1920 times per frame; eliminating the two call frames is measurable.
(declaim (inline %emit-fg %emit-bg))

(define-colour-emitters
  ;;        name       label         std  bright  256-pfx  tc-pfx  default
  (%emit-fg "foreground"              30    82    "38;5"   "38;2"   39)
  (%emit-bg "background"              40    92    "48;5"   "48;2"   49))

;;; ── Underline colour (SGR 58) ────────────────────────────────────────────────
;;;
;;; Unlike fg/bg, the underline colour has no 30-37/40-47 "standard" short-form:
;;; all indices use the 58;5;N 256-colour form or 58;2;R;G;B for true-colour.
;;; 0 means "default" (inherit from fg) and is never emitted.
(declaim (inline %emit-ul-color))

(defun %emit-ul-color (stream n)
  "Emit the SGR underline-colour fragment for N: ';58;5;N' for palette, ';58;2;R;G;B'
   for true-colour (bit 24 set).  Skips emission when N is zero (default = inherit fg)."
  (when (plusp n)
    (if (logbitp 24 n)
        (let ((rgb (logand n #xFFFFFF)))
          (format stream
                  ";58;2;~D;~D;~D"
                  (ash rgb -16)
                  (logand (ash rgb -8) #xFF)
                  (logand rgb #xFF)))
        (format stream ";58;5;~D" n))))

;;; ── Attribute rendering ─────────────────────────────────────────────────────
;;;
;;; define-cell-attr-renderer is a Prolog-like rule table:
;;;   render_attr(bold, stream)      :- write(stream, ";1").
;;;   render_attr(italic, stream)    :- write(stream, ";3").
;;;   ...
;;;
;;; ATTRS2 extended attributes (double-underline SGR 21, overline SGR 53) and
;;; UL-COLOR (SGR 58) are optional; zero means "not set / default".
(define-cell-attr-renderer
  (0 1)    ; bold          → SGR 1
  (1 2)    ; dim           → SGR 2
  (2 7)    ; reverse       → SGR 7
  (3 4)    ; underline     → SGR 4
  (4 5)    ; blink         → SGR 5
  (5 3)    ; italic        → SGR 3
  (6 8)    ; conceal       → SGR 8
  (7 9)) ; strikethrough → SGR 9

;;; ── Cursor visibility ───────────────────────────────────────────────────────
(defun cursor-invisible (stream)
  "Emit DECTCEM hide-cursor sequence ESC[?25l to STREAM."
  (write-string (cl-tty-kit:ansi-hide-cursor) stream))

(defun cursor-visible (stream)
  "Emit DECTCEM show-cursor sequence ESC[?25h to STREAM."
  (write-string (cl-tty-kit:ansi-show-cursor) stream))

(defun set-cursor-shape (stream shape)
  "Emit DECSCUSR CSI sequence to set cursor shape in the outer terminal."
  (format stream "~C[~D q" +esc+ shape))

;;; ── Attribute reset ─────────────────────────────────────────────────────────
(defun %emit-sgr (stream code)
  "Emit an ANSI SGR escape sequence (ESC[CODEm) to STREAM.
   CODE may be an integer or a string (e.g. \"44;96\" for compound SGR parameters).
   A no-op when CODE is NIL — allows callers to pass optional style codes directly."
  (when code
    (format stream "~C[~Am" +esc+ code)))

(defun reset-attrs (stream)
  "Emit SGR reset sequence ESC[0m to STREAM, clearing all attributes and colours."
  (write-string (cl-tty-kit:ansi-reset-style) stream))

;;; ── Layout helpers ──────────────────────────────────────────────────────────
(defun %center-coord (total size)
  "Return the column/row offset to center SIZE within TOTAL (clamped to 0)."
  (max 0 (floor (- total size) 2)))

;;; ── Display-width text clipping (R6.9) ────────────────────────────────────
;;;
;;; The emulator side treats a full-width character (CJK, kana, hangul, most
;;; emoji) as two terminal cells -- %place-wide-char and CHAR-WIDTH in
;;; src/domain/terminal/. Column math here used to count (LENGTH TEXT)
;;; instead, so a path or branch name containing Japanese desynced by one
;;; cell per wide character. These two functions are the one place plain
;;; (non-SGR) text gets measured and truncated by display width; every clip
;;; site outside the status bar's own SGR-aware layer (renderer-statusbar-
;;; layout.lisp, which has a parallel fix) routes through them instead of
;;; repeating the column math locally.
;;;
;;; CHAR-WIDTH lives in NERIMUX/TERMINAL/TYPES and is not re-exported by the
;;; NERIMUX/TERMINAL facade package that NERIMUX/RENDERER otherwise :USEs
;;; (package-terminal.lisp's :export list omits it) -- referenced here fully
;;; qualified rather than through the facade. This is a downward reference
;;; (DOMAIN -> DOMAIN, both PRESENTATION's dependency direction), so it does
;;; not trip the layering guard, but it does bypass the facade's stated
;;; purpose of keeping callers off individual sub-packages.
(defun %display-width (text)
  "Sum of NERIMUX/TERMINAL/TYPES:CHAR-WIDTH across TEXT's characters: the
   number of terminal columns TEXT occupies, as opposed to (LENGTH TEXT)."
  (loop for ch across text
        sum (nerimux/terminal/types:char-width ch)))

(defun %display-clip (value width)
  "Clip VALUE (coerced to a string) to fit within WIDTH display columns,
   measured by CHAR-WIDTH rather than (LENGTH TEXT). A character that would
   straddle the WIDTH boundary is dropped whole, never split, and the
   resulting short column is padded with spaces so a fixed-width caller's
   layout does not shift. WIDTH >= 4 keeps a 3-column \"...\" suffix (as the
   pre-R6.9 length-based clip did); a narrower WIDTH truncates without one.
   The returned string's display width always equals WIDTH once VALUE
   exceeds it."
  (let* ((text
          (if (stringp value)
              value
              (princ-to-string value)))
         (width (max 0 width)))
    (if (<= (%display-width text) width)
        text
        (let* ((ellipsis-p (>= width 4))
               (budget
                (if ellipsis-p
                    (- width 3)
                    width))
               (taken 0)
               (end 0))
          (loop for index from 0 below (length text)
                for w = (nerimux/terminal/types:char-width (char text index))
                while (<= (+ taken w) budget)
                do (incf taken w) (setf end (1+ index)))
          (concatenate 'string
                       (subseq text 0 end)
                       (make-string (- budget taken) :initial-element #\Space)
                       (if ellipsis-p
                           "..."
                           ""))))))

;;; ── SGR-aware width math ────────────────────────────────────────────────────
;;;
;;; Moved here from renderer-statusbar-layout.lisp: the workspace frame's
;;; styled header/footer rows need the same escape-skipping clip math the
;;; status bar uses, and this file loads ahead of both consumers.
(defun %sgr-sequence-end (str start)
  "If STR has a CSI escape starting at START, return the index just past its final byte.
   Otherwise returns NIL.

   CSI encoding: ESC (0x1B) '[' (0x5B) <parameter-bytes 0x30–0x3F>*
                 <intermediate-bytes 0x20–0x2F>* <final-byte 0x40–0x7E>.
   The function skips all bytes until the first final-byte or end of string,
   returning (1+ final-byte-index) on success, or LEN when the sequence is
   unterminated.  Callers should treat an unterminated sequence as consuming
   the rest of the string."
  (let ((len (length str)))
    (when 
        (and (< (1+ start) len)
             (char= (char str start) +esc+)
             (char= (char str (1+ start)) #\[))
      (let ((j (+ start 2)))
        (loop while (and (< j len)
                         (not (<= #x40 (char-code (char str j)) #x7e)))
              do (incf j))
        (if (< j len)
            (1+ j)
            len)))))

(defun %visible-length (str)
  "Display-column width of STR, skipping CSI SGR escape sequences and
   counting each remaining character by NERIMUX/TERMINAL/TYPES:CHAR-WIDTH
   (0/1/2 — R6.9) rather than by character count, so a fullwidth window or
   session name (CJK, kana, hangul) does not desync status-bar column math
   the way (LENGTH STR) would.  Equals (LENGTH STR) for escape-free ASCII."
  (let ((n 0)
        (i 0)
        (len (length str)))
    (loop while (< i len)
          for esc-end = (%sgr-sequence-end str i)
          do (if esc-end
                 (setf i esc-end)
                 (progn
                   (incf n (nerimux/terminal/types:char-width (char str i)))
                   (incf i))))
    n))

(defun %visible-truncate (str n)
  "Prefix of STR holding at most N display columns; CSI escape sequences are
   copied through without counting toward N, and a fullwidth character that
   would straddle the N-column boundary is dropped whole rather than split
   (R6.9) — the caller's own gap math (e.g. %JUSTIFY-RIGHT, %STATUS-PAD-TO)
   already fills the resulting short column with spaces, so this does not
   pad itself.  Equals (SUBSEQ STR 0 (MIN N (LENGTH STR))) for escape-free
   ASCII."
  (if (>= n (%visible-length str))
      str
      (with-output-to-string (out)
        (let ((seen 0)
              (i 0)
              (len (length str)))
          (loop while (and (< i len) (< seen n))
                for esc-end = (%sgr-sequence-end str i)
                do (if esc-end
                       (progn
                         (write-string str out :start i :end esc-end)
                         (setf i esc-end))
                       (let ((w
                              (nerimux/terminal/types:char-width (char str i))))
                         (if (<= (+ seen w) n)
                             (progn
                               (write-char (char str i) out)
                               (incf seen w)
                               (incf i))
                             (setf i len)))))))))

(defun %display-clip-tail (text width)
  "Return the trailing slice of TEXT whose display width fits within WIDTH,
   trimming from the front rather than the back -- the shape a live-edited
   command buffer needs so the cursor position (always at the end) stays
   visible, as opposed to %DISPLAY-CLIP's fixed-label truncation. Never
   splits a wide character; WIDTH or more columns of TEXT come back
   unchanged."
  (let ((width (max 0 width))
        (length (length text)))
    (if (<= (%display-width text) width)
        text
        (let ((taken 0)
              (start length))
          (loop for index from (1- length) downto 0
                for w = (nerimux/terminal/types:char-width (char text index))
                while (<= (+ taken w) width)
                do (incf taken w) (setf start index))
          (subseq text start)))))

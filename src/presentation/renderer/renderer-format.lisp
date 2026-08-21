(in-package #:nerimux/renderer)

;;;; ANSI escape-code primitives — pure data layer.
;;;;
;;;; All functions here write escape sequences to a stream; they do not touch
;;;; any model or terminal state.

(defconstant +esc+ #\Escape)

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
;;; Real tmux's -2 flag ("force 256-colour") exists because not every outer
;;; terminal understands 24-bit SGR (38;2;R;G;B).  nerimux always emitted
;;; true-colour unconditionally; *color-downsample-fn*, set from -2 by
;;; %apply-global-cli-invocation (main-startup-flags.lisp), routes true-colour
;;; cell values through cl-tty-kit:rgb-to-256 before classification so -2
;;; sessions degrade gracefully instead of leaking raw 24-bit escapes.

(defvar *color-downsample-fn* nil
  "Optional function (packed-rgb-int) -> palette-index, applied to TRUE-COLOR
   values (bit 24 set) before %EMIT-FG/%EMIT-BG classify them.  NIL (the
   default) emits true-colour unchanged, so the hot per-cell path pays only a
   single NULL check in the common case.")

(defun %rgb-int-to-256 (n)
  "Downsample packed true-colour int N (bit 24 set; RGB in bits 16-0) to the
   nearest xterm 256-palette index via cl-tty-kit:rgb-to-256."
  (let ((rgb (logand n #xFFFFFF)))
    (cl-tty-kit:rgb-to-256 (ash rgb -16) (logand (ash rgb -8) #xFF) (logand rgb #xFF))))

(declaim (inline %maybe-downsample-color))
(defun %maybe-downsample-color (n)
  "Return N, or its *color-downsample-fn* projection when N is true-colour."
  (if (and *color-downsample-fn* (logbitp 24 n))
      (funcall *color-downsample-fn* n)
      n))

;;; %EMIT-FG and %EMIT-BG are inlined: render-pane calls render-cell-attrs up
;;; to ~1920 times per frame; eliminating the two call frames is measurable.
(declaim (inline %emit-fg %emit-bg))

(defmacro define-colour-emitters (&rest specs)
  "Build %EMIT-FG and %EMIT-BG from a declarative spec table.
   Each SPEC is (name label std-base bright-base palette-prefix tc-prefix default-val).
   bright-base is std-base + 60 (i.e. 30+60=90 for fg, 40+60=100 for bg), offset
   by -8 so that (+ bright-base palette-index) yields the target SGR code directly
   for indices 8-15:  82+8=90, 82+15=97 for fg; 92+8=100, 92+15=107 for bg."
  `(progn
     ,@(mapcar
        (lambda (spec)
          (destructuring-bind (name label std-base bright-base
                               palette-prefix tc-prefix default-val) spec
            `(defun ,name (stream n)
               ,(format nil
                  "Emit the ANSI SGR ~A colour code for value N to STREAM.~%~
                   N < 0: emit nothing (out-of-range / no-colour sentinel for tests).~%~
                   0-7:   standard colours   → ;~D-~D~%~
                   8-15:  bright colours     → ;~D-~D~%~
                   16-255: 256-colour palette → ;~A;N~%~
                   bit 24 set (#x1000000+): true-color → ;~A;R;G;B"
                  label std-base (+ std-base 7) bright-base (+ bright-base 7)
                  palette-prefix tc-prefix)
               ;; The (>= n 0) guard handles callers (e.g. unit tests) that pass -1
               ;; as a "no colour" sentinel.  Normal callers always pass (unsigned-byte 25)
               ;; values from cell-fg / cell-bg, which are always non-negative.
               (when (>= n 0)
                 (let ((n (%maybe-downsample-color n)))
                   (cond
                     ;; True-color: bit 24 set → #x1RRGGBB (unless downsampled above)
                     ((logbitp 24 n)
                      (let* ((rgb (logand n #xFFFFFF))
                             (r (ash rgb -16))
                             (g (logand (ash rgb -8) #xFF))
                             (b (logand rgb #xFF)))
                        (format stream ";~A;~D;~D;~D" ,tc-prefix r g b)))
                     ((<= 0    n  7)   (format stream ";~D"      (+ ,std-base    n)))
                     ((<= 8    n 15)   (format stream ";~D"      (+ ,bright-base n)))
                     ((<= 16   n 255)  (format stream ";~A;~D"   ,palette-prefix n))
                     ;; Defensive fallback for values 256-#xFFFFFF without bit 24.
                     ;; Unreachable via apply-sgr (palette clamped to 255, true-color
                     ;; sets bit 24). Emits the default-colour reset code.
                     (t                (format stream ";~D"       ,default-val))))))))
        specs)))

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
          (format stream ";58;2;~D;~D;~D"
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

(defmacro define-cell-attr-renderer (&rest bit-rules)
  "Build RENDER-CELL-ATTRS from a declarative table of (bit-index sgr-code) entries.
   Attribute bits are checked in order and the corresponding SGR code is emitted.
   The generated function also accepts ATTRS2 (extended attributes: double-underline
   and overline) and UL-COLOR (underline colour, SGR 58); both default to 0."
  `(defun render-cell-attrs (stream fg bg attrs &optional (attrs2 0) (ul-color 0))
     "Emit an SGR escape sequence resetting then applying FG, BG, ATTRS, ATTRS2 extended
      attributes (double-underline SGR 21, overline SGR 53), and UL-COLOR underline colour."
     (declare (type (unsigned-byte 8) attrs attrs2) (type (unsigned-byte 25) ul-color))
     (format stream "~C[0" +esc+)
     ,@(mapcar (lambda (rule)
                 `(when (logbitp ,(first rule) attrs)
                    (write-string ,(format nil ";~D" (second rule)) stream)))
               bit-rules)
     ;; Extended attribute bits (attrs2): double-underline (bit 0) and overline (bit 1)
     (when (logbitp 0 attrs2) (write-string ";21" stream)) ; SGR 21 — doubly underlined
     (when (logbitp 1 attrs2) (write-string ";53" stream)) ; SGR 53 — overlined
     (%emit-fg stream fg)
     (%emit-bg stream bg)
     ;; Underline colour (SGR 58); 0 = default (inherit fg) → no emission
     (%emit-ul-color stream ul-color)
     (write-char #\m stream)))

(define-cell-attr-renderer
  (0 1)    ; bold          → SGR 1
  (1 2)    ; dim           → SGR 2
  (2 7)    ; reverse       → SGR 7
  (3 4)    ; underline     → SGR 4
  (4 5)    ; blink         → SGR 5
  (5 3)    ; italic        → SGR 3
  (6 8)    ; conceal       → SGR 8
  (7 9))   ; strikethrough → SGR 9

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
  (when code (format stream "~C[~Am" +esc+ code)))

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
  (loop for ch across text sum (nerimux/terminal/types:char-width ch)))

(defun %display-clip (value width)
  "Clip VALUE (coerced to a string) to fit within WIDTH display columns,
   measured by CHAR-WIDTH rather than (LENGTH TEXT). A character that would
   straddle the WIDTH boundary is dropped whole, never split, and the
   resulting short column is padded with spaces so a fixed-width caller's
   layout does not shift. WIDTH >= 4 keeps a 3-column \"...\" suffix (as the
   pre-R6.9 length-based clip did); a narrower WIDTH truncates without one.
   The returned string's display width always equals WIDTH once VALUE
   exceeds it."
  (let* ((text (if (stringp value) value (princ-to-string value)))
         (width (max 0 width)))
    (if (<= (%display-width text) width)
        text
        (let* ((ellipsis-p (>= width 4))
               (budget (if ellipsis-p (- width 3) width))
               (taken 0)
               (end 0))
          (loop for index from 0 below (length text)
                for w = (nerimux/terminal/types:char-width (char text index))
                while (<= (+ taken w) budget)
                do (incf taken w) (setf end (1+ index)))
          (concatenate 'string
                       (subseq text 0 end)
                       (make-string (- budget taken) :initial-element #\Space)
                       (if ellipsis-p "..." ""))))))

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
        (let ((taken 0) (start length))
          (loop for index from (1- length) downto 0
                for w = (nerimux/terminal/types:char-width (char text index))
                while (<= (+ taken w) width)
                do (incf taken w) (setf start index))
          (subseq text start)))))

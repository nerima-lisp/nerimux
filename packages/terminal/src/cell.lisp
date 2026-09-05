(in-package #:nerimux/terminal/types)

(defconstant +attr-bold+
  #b00000001)

(defconstant +attr-dim+
  #b00000010)

(defconstant +attr-reverse+
  #b00000100)

(defconstant +attr-underline+
  #b00001000)

(defconstant +attr-blink+
  #b00010000)

(defconstant +attr-italic+
  #b00100000)

(defconstant +attr-conceal+
  #b01000000)

(defconstant +attr-strikethrough+
  #b10000000)

(defconstant +attr2-double-underline+
  #b00000001) ; SGR 21

(defconstant +attr2-overline+
  #b00000010) ; SGR 53

(defconstant +true-color-flag+
  #x1000000
  "Bit 24 of a colour slot: when set, bits 23-16 are R, 15-8 are G, 7-0 are B.
   Values 0-255 are palette indices; values >= +true-color-flag+ are true-colour RGB.")

(defconstant +default-color+
  256
  "Sentinel colour value meaning \"the terminal default\" (SGR 39 fg / SGR 49 bg).
   Placed at 256 — just above the 0-255 palette and without the
   +true-color-flag+ bit — so it is distinct from palette index 7 (white)
   and 0 (black).  Cells carrying this value are the only ones
   window-style / window-active-style may recolour.")

(defconstant +unicode-replacement-char+
  #xFFFD
  "Unicode code point U+FFFD REPLACEMENT CHARACTER.
   Used as a fallback for invalid or unrepresentable code points.")

(defconstant +default-screen-width+
  80
  "Default virtual terminal width in columns (VT100 standard).")

(defconstant +default-screen-height+
  24
  "Default virtual terminal height in rows (VT100 standard).")

(defconstant +title-stack-max-depth+
  8
  "Maximum depth of the XTPUSHTITLE / XTPOPTITLE title stack (matches xterm).")

(defconstant +osc-default-fg+
  #xFFFFFF
  "Default foreground colour for OSC 10/110 colour resets (white).")

(defconstant +osc-default-bg+
  #x000000
  "Default background colour for OSC 11/111 colour resets (black).")

(defstruct cell
  "One character position on the virtual screen.

   WIDTH encodes East-Asian double-width handling:
     1 — normal single-column cell
     2 — lead cell of a double-width character
     0 — continuation placeholder occupied by the wide char to its left

   Color encoding (fg, bg, ul-color):
     0-255            — palette index (0-7 standard, 8-15 bright, 16-255 extended)
     >= +true-color-flag+ — true-colour RGB: bits 23-16 R, 15-8 G, 7-0 B"
  (char  #\Space :type character)
  (fg    +default-color+ :type (unsigned-byte 25))
  (bg    +default-color+ :type (unsigned-byte 25))
  (attrs 0       :type (unsigned-byte 8))   ; bit-field: see +attr-* constants
  (attrs2 0      :type (unsigned-byte 8))
  (ul-color 0   :type (unsigned-byte 25))
  (combining nil :type list)
  (hyperlink nil :type (or null string))
  (width 1       :type (integer 0 2))) ; 1 normal, 2 wide lead, 0 continuation

(defun blank-cell ()
  "Return a fresh default (space, default fg/bg sentinel, no attrs, single-width) cell."
  (make-cell))

(declaim (inline clamp))

(defun clamp (v lo hi)
  "Clamp integer V to the closed interval [LO, HI]."
  (max lo (min hi v)))

(defconstant +surrogate-first+
  #xD800
  "First UTF-16 surrogate code point.  D800-DFFF are reserved for UTF-16 pairing
   and are NOT Unicode scalar values, so no well-formed UTF-8 encodes one.")

(defconstant +surrogate-last+
  #xDFFF
  "Last UTF-16 surrogate code point.  See +SURROGATE-FIRST+.")

(defun surrogate-code-point-p (cp)
  "Return T when CP lies in the UTF-16 surrogate block D800-DFFF.

   SBCL's CHAR-CODE-LIMIT does not exclude this block: (CODE-CHAR #xD800) yields
   a real character object, so a bare (< cp CHAR-CODE-LIMIT) guard admits a lone
   surrogate into a string.  Such a string cannot be UTF-8 encoded — SBCL's
   encoder signals on it — so it must be rejected where it enters, not where it
   is written out."
  (<= +surrogate-first+ cp +surrogate-last+))

(defun safe-code-char (cp)
  "CODE-CHAR guarded against invalid code points; falls back to U+FFFD.

   A lone surrogate counts as invalid.  A child process can emit the three bytes
   ED A0 80, which nerimux's own UTF-8 continuation decoder (parser-utf8.lisp)
   reassembles into code point #xD800; without this guard that lone surrogate
   would be stored in a screen cell and then reach
   CL-CODEC-KIT:STRING-TO-OCTETS on the render/broadcast path (protocol.lisp
   MSG-FRAME), which signals rather than encoding it.  Substituting U+FFFD here
   is what a terminal should display for an unpaired surrogate anyway, and it
   keeps every octet-encoding call site on the strict :ERRORP T default, so a
   genuine defect still surfaces."
  (or
   (and (< cp char-code-limit) (not (surrogate-code-point-p cp)) (code-char cp))
   (code-char +unicode-replacement-char+)))

(declaim (inline char-width))

(defun char-width (ch)
  "Display column width of CH: 0 for zero-width characters (combining marks,
   enclosing marks, format controls), 2 for East-Asian Wide / Fullwidth
   characters (CJK, kana, hangul, fullwidth forms, most emoji), 1 otherwise.
   Ambiguous-width ranges (box drawing) are treated as 1.

   Delegates to CL-TTY-KIT:CHAR-WIDTH, whose Unicode width data and general
   category handling keep column counts aligned with terminal rendering. Three
   representative cases are:

     * U+0301 COMBINING ACUTE ACCENT (Mn) — table said 1, true width is 0.
     * U+309A COMBINING KATAKANA-HIRAGANA SEMI-VOICED SOUND MARK — the table's
       blanket #x3041-#x33FF \"Hiragana, Katakana\" range said 2 for a mark that
       occupies no columns at all, so one mark desynchronised a line by two.
     * U+231A WATCH — East Asian Wide, but outside the table's emoji range
       (#x1F300-#x1FAFF), so it was counted 1 and drawn 2.

   nshell already delegates the same way; keeping a second table here meant two
   answers to one Unicode question."
  (cl-tty-kit:char-width ch))

(in-package #:nerimux/terminal/actions)

;;;; Character writing: combining marks, DEC special graphics remapping, and
;;;; wide/normal cell placement at the cursor.
;;;; Loads after cursor.lisp (needs cursor-down/scroll) and edit.lisp (needs
;;;; insert-chars for IRM).

(declaim (inline %mark-dirty))
(defun %mark-dirty (screen)
  "Mark SCREEN dirty: signal the renderer that cells have changed."
  (setf (screen-dirty-p screen) t))

(defun %advance-cursor (screen n)
  "Advance the cursor N columns after a write.  When the write reaches the right
   margin with autowrap on, the wrap is DEFERRED (VT100 last-column flag): the
   cursor stays parked at the last column and screen-pending-wrap is set, so the
   wrap happens only when the next character arrives (see write-char-at-cursor).
   With autowrap off the cursor clamps at the last column (the write overwrites)."
  (let ((next-x (+ (screen-cursor-x screen) n)))
    (cond
      ;; Advance: fits within the current row.
      ((< next-x (screen-width screen))
       (setf (screen-cursor-x screen) next-x))
      ;; Reached the right margin with autowrap on: defer the wrap, park at the
      ;; last column.  The next printable char performs the wrap.
      ((screen-autowrap screen)
       (setf (screen-cursor-x screen) (1- (screen-width screen))
             (screen-pending-wrap screen) t))
      ;; Clamp: reached the right margin and autowrap is off.
      (t
       (setf (screen-cursor-x screen) (1- (screen-width screen)))))))

(defun %place-wide-char (screen x y char fg bg attrs attrs2 ul-color hyperlink)
  "Place a double-width character at (X,Y) and write its continuation cell.
   The continuation cell is written only if (1+ X) is within the screen."
  (setf (screen-cell screen x y)
        (make-cell :char char :fg fg :bg bg :attrs attrs :attrs2 attrs2
                   :ul-color ul-color :hyperlink hyperlink :width 2))
  (when (< (1+ x) (screen-width screen))
    (setf (screen-cell screen (1+ x) y)
          (make-cell :char #\Space :fg fg :bg bg :attrs attrs :attrs2 attrs2
                     :ul-color ul-color :hyperlink hyperlink :width 0))))

;;; DEC special graphics character set (G1; activated by ESC ( 0).
;;; Maps ASCII code points (in the range used by line-drawing apps) to the
;;; corresponding Unicode box-drawing characters.
;;;
;;; Prolog-like fact table — each entry is one character mapping:
;;;   dec_graphics(j, '┘').  dec_graphics(k, '┐').  ...
;;; The define-dec-graphics-table macro builds the case form from this table.

(defmacro define-dec-graphics-table (&rest mappings)
  "Generate %DEC-GRAPHICS-CHAR from a declarative character-mapping table.
   Each MAPPING is (ascii-char unicode-char description) where description is
   a compile-time annotation only."
  `(defun %dec-graphics-char (ch)
     "Remap CH from the DEC special graphics set to the corresponding Unicode
      box-drawing character.  Returns CH unchanged for unmapped code points."
     (case ch
       ,@(mapcar (lambda (m) `(,(first m) ,(second m))) mappings)
       (t ch))))

(define-dec-graphics-table
  ;; Box-drawing corners
  (#\j #\┘ "lower-right corner")
  (#\k #\┐ "upper-right corner")
  (#\l #\┌ "upper-left corner")
  (#\m #\└ "lower-left corner")
  ;; Box-drawing junctions
  (#\n #\┼ "crossing")
  (#\t #\├ "left tee")
  (#\u #\┤ "right tee")
  (#\v #\┴ "bottom tee")
  (#\w #\┬ "top tee")
  ;; Vertical line + the nine horizontal scan lines.  The DEC set places nine
  ;; horizontal rules at distinct vertical positions; q (scan line 5) is the
  ;; middle = the box-drawing horizontal, o/p sit above it, r/s below.  Mapping
  ;; each to its exact scan-line glyph (not all to ─) preserves the rule height an
  ;; app intends (e.g. a double rule drawn with o + s).
  (#\x #\│ "vertical line")
  (#\o #\⎺ "scan line 1 (top)")
  (#\p #\⎻ "scan line 3")
  (#\q #\─ "scan line 5 / horizontal line")
  (#\r #\⎼ "scan line 7")
  (#\s #\⎽ "scan line 9 (bottom)")
  ;; Special characters
  (#\a #\▒ "checkerboard")
  (#\` #\◆ "diamond")
  (#\f #\° "degree symbol")
  (#\g #\± "plus-minus")
  ;; Math / relational symbols (upper half of the DEC special-graphics set —
  ;; these are emitted by real apps and were previously passed through literally).
  (#\y #\≤ "less-than-or-equal")
  (#\z #\≥ "greater-than-or-equal")
  (#\{ #\π "pi")
  (#\| #\≠ "not-equal")
  (#\} #\£ "UK pound sign")
  (#\~ #\· "centred dot / bullet")
  (#\_ #\Space "blank")
  ;; Control-code picture glyphs (rarely emitted; included to complete the set).
  (#\b #\␉ "horizontal tab (HT)")
  (#\c #\␌ "form feed (FF)")
  (#\d #\␍ "carriage return (CR)")
  (#\e #\␊ "line feed (LF)")
  (#\h #\␤ "newline (NL)")
  (#\i #\␋ "vertical tab (VT)"))

;;; ── Combining characters ───────────────────────────────────────────────────
;;;
;;; A combining character occupies no terminal column and belongs to the
;;; grapheme cluster of the character before it, so it is appended to the
;;; previous cell instead of being placed in a new one.
;;;
;;; The DEFINITION is CHAR-WIDTH: a character combines exactly when it is
;;; zero-width, minus the control-code carve-out below.  This is the general
;;; terminal rule: a cell of width 0 is always routed to the combining path,
;;; never placed as its own cell.
;;;
;;; It replaces a hand-written list of five ranges, which was a second answer to
;;; a question CHAR-WIDTH already answers, and disagreed with it in both
;;; directions:
;;;
;;;   * It missed U+3099 / U+309A (COMBINING KATAKANA-HIRAGANA VOICED /
;;;     SEMI-VOICED SOUND MARK), every Arabic, Hebrew, Devanagari and Thai mark,
;;;     and every variation selector.  Each took a column here while CHAR-WIDTH
;;;     said it took none, so the IRM insert gap (%APPLY-INSERT-MODE-GAP, which
;;;     asks CHAR-WIDTH) and the cursor advance (%WRITE-NORMAL-CELL, which did
;;;     not) disagreed by one cell per mark.
;;;   * It over-claimed on the unassigned tails of its own ranges: U+1ACF-1AFF
;;;     and U+20F1-20FF are Cn, which CHAR-WIDTH counts as one column.
;;;
;;; Deliberately IN scope, and pinned by tests in char-write-tests.lisp:
;;;
;;;   * Cf format controls combine: U+200D ZWJ, U+200B ZWSP, U+200C ZWNJ,
;;;     U+FEFF, the bidi marks.  An emoji ZWJ sequence is then the width of its
;;;     glyphs with no stray column between them.  U+00AD SOFT HYPHEN is the one
;;;     Cf that CHAR-WIDTH exempts (a terminal draws it when it breaks a line),
;;;     so it keeps its column here too, for free.
;;;   * Me enclosing marks combine (U+20DD COMBINING ENCLOSING CIRCLE).
;;;   * Hangul Jamo medial vowels and final consonants U+1160-U+11FF combine;
;;;     they compose onto the leading jamo, which is why CHAR-WIDTH carries an
;;;     explicit zero-width range for them despite their Lo category.
;;;
;;; Deliberately OUT of scope: control codes.  CHAR-WIDTH reports 0 for every C0
;;; and C1 code point (NUL, TAB, ESC, U+0080-U+009F) because they are not
;;; printed — not because they attach to the character before them.  GROUND-STATE
;;; in parser.lisp dispatches C0 bytes to CURSOR-HT / CURSOR-NL / ... and never
;;; hands one to WRITE-CHAR-AT-CURSOR, but a C1 control still arrives through
;;; WRITE-CODEPOINT: the UTF-8 decoder assembles the two bytes C2 80 into
;;; U+0080.  The carve-out is therefore a guard, not a comment — without it that
;;; byte pair would silently glue itself onto the previous cell.

(defun %control-char-p (ch)
  "Return T when CH is a C0 or C1 control code point.
   Mirrors the control test inside CL-TTY-KIT:CHAR-WIDTH, which is the reason it
   answers 0 for these; see the commentary above for why that 0 does not mean
   \"combining\"."
  (let ((cp (char-code ch)))
    (or (< cp #x20)
        (<= #x7F cp #x9F))))

(defun combining-char-p (ch)
  "Return T if CH is a zero-width combining character: one that occupies no
   terminal column and belongs to the preceding character's grapheme cluster.
   Agrees with CHAR-WIDTH on every non-control code point by construction;
   control codes are excluded deliberately (see above)."
  (and (not (%control-char-p ch))
       (zerop (char-width ch))))

(defun %combining-target-x (screen)
  "Column of the cell a combining mark written at the cursor belongs to.
   Normally the column left of the cursor.  At column 0 there is no such cell,
   so column 0 itself is used — the only cell available on that row.

   When the cell to the left is a double-width character's continuation
   placeholder (width 0), the mark belongs to that character's LEAD cell, one
   column further left: か followed by U+3099 must read as が.  Attaching it to
   the placeholder would drop it outright, because %RENDER-CELL-ROW emits
   nothing for a width-0 cell — the outer terminal already drew both columns of
   the glyph to its left."
  (let ((x (screen-cursor-x screen)))
    (cond ((zerop x) 0)
          ((and (> x 1)
                (zerop (cell-width (screen-cell screen (1- x) (screen-cursor-y screen)))))
           (- x 2))
          (t (1- x)))))

(defun %append-combining-char (screen ch)
  "Append combining character CH to the cell the cursor's write position belongs
   to (see %COMBINING-TARGET-X).  The cursor is NOT advanced."
  (let* ((prev-x    (%combining-target-x screen))
         (prev-y    (screen-cursor-y screen))
         (prev-cell (screen-cell screen prev-x prev-y)))
    (setf (screen-cell screen prev-x prev-y)
          (make-cell :char      (cell-char     prev-cell)
                     :fg        (cell-fg       prev-cell)
                     :bg        (cell-bg       prev-cell)
                     :attrs     (cell-attrs    prev-cell)
                     :attrs2    (cell-attrs2   prev-cell)
                     :ul-color  (cell-ul-color prev-cell)
                     :combining (append (cell-combining prev-cell) (list ch))
                     :width     (cell-width    prev-cell)))
    (%mark-dirty screen)))

(defun %remap-charset-char (screen ch)
  "Remap CH through the DEC special graphics table when the effective charset
   calls for it.  A pending single shift (SS2/SS3) takes precedence: it maps
   THIS character through the shifted G set's designation and then clears —
   otherwise the locking-shift effective charset (screen-charset) applies."
  (let ((shift (screen-single-shift screen)))
    (cond
      (shift
       (setf (screen-single-shift screen) nil)
       (if (eq (screen-invoked-charset screen shift) :dec-graphics)
           (%dec-graphics-char ch)
           ch))
      ((eq (screen-charset screen) :dec-graphics)
       (%dec-graphics-char ch))
      (t ch))))

(defun %write-wide-cell (screen ch)
  "Write double-width character CH at the cursor.
   Wraps to the next row first if the character does not fit in the last column.
   Advances the cursor by 2 after placing the lead + continuation cells."
  (let ((fg       (screen-cur-fg       screen))
        (bg       (screen-cur-bg       screen))
        (attrs    (screen-cur-attrs    screen))
        (attrs2   (screen-cur-attrs2   screen))
        (ul-color (screen-cur-ul-color screen)))
    ;; If the wide char cannot fit (only one column remains), blank the last
    ;; column and wrap to the next row before placing it.
    (when (>= (1+ (screen-cursor-x screen)) (screen-width screen))
      (setf (screen-cell screen (screen-cursor-x screen) (screen-cursor-y screen)) (blank-cell)
            (screen-cursor-x screen) 0)
      (cursor-down/scroll screen))
    (%place-wide-char screen (screen-cursor-x screen) (screen-cursor-y screen)
                      ch fg bg attrs attrs2 ul-color
                      (screen-current-hyperlink screen))
    (%mark-dirty screen)
    (%advance-cursor screen 2)))

(defun %write-normal-cell (screen ch)
  "Write single-width character CH at the cursor and advance by 1."
  (let ((x        (screen-cursor-x    screen))
        (y        (screen-cursor-y    screen))
        (fg       (screen-cur-fg      screen))
        (bg       (screen-cur-bg      screen))
        (attrs    (screen-cur-attrs   screen))
        (attrs2   (screen-cur-attrs2  screen))
        (ul-color (screen-cur-ul-color screen)))
    (setf (screen-cell screen x y)
          (make-cell :char ch :fg fg :bg bg :attrs attrs :attrs2 attrs2
                     :ul-color ul-color :hyperlink (screen-current-hyperlink screen)
                     :width 1))
    (%mark-dirty screen)
    (%advance-cursor screen 1)))

(defun %consume-pending-wrap (screen)
  "Perform a deferred VT100 wrap if one is pending: the previous write parked
   the cursor at the last column with autowrap on, so the NEXT character
   triggers the actual wrap to column 0 of the following row.  Records the
   row as wrapped for capture-pane -J before cursor-down/scroll, which may
   shift the wrap flags."
  (when (screen-pending-wrap screen)
    (%mark-line-wrapped screen (screen-cursor-y screen))
    (setf (screen-pending-wrap screen) nil
          (screen-cursor-x screen) 0)
    (cursor-down/scroll screen)))

(defun %apply-insert-mode-gap (screen ch)
  "IRM (insert mode): when active, open a gap of CH's display width at the
   cursor so the new character pushes the rest of the line right instead of
   overwriting it."
  (when (screen-insert-mode screen)
    (insert-chars screen (char-width ch))))

(defun write-char-at-cursor (screen ch)
  "Write CH at the cursor, then advance.  Double-width (CJK) characters occupy
   a lead cell plus a continuation placeholder and advance the cursor by two;
   a wide char that will not fit at the right edge wraps to the next line first.
   Records CH as the screen's LAST-CHAR for use by CSI REP sequences.

   When CH is a Unicode combining character, it is appended to the previous cell
   and the cursor is NOT advanced.

   When the screen's charset is :dec-graphics, CH is remapped through the DEC
   special graphics table before being written."
  (if (combining-char-p ch)
      (%append-combining-char screen ch)
      (let ((remapped-ch (progn
                            (%consume-pending-wrap screen)
                            (%remap-charset-char screen ch))))
        (setf (screen-last-char screen) remapped-ch)
        (%apply-insert-mode-gap screen remapped-ch)
        (if (= (char-width remapped-ch) 2)
            (%write-wide-cell   screen remapped-ch)
            (%write-normal-cell screen remapped-ch)))))

(defun write-codepoint (screen cp)
  "Write Unicode code point CP at the cursor, converting it via SAFE-CODE-CHAR."
  (write-char-at-cursor screen (safe-code-char cp)))

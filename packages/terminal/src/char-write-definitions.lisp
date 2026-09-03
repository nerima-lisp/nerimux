(in-package #:nerimux/terminal/actions)

(defmacro define-dec-graphics-table (&rest mappings)
  "Generate %DEC-GRAPHICS-CHAR from a declarative character-mapping table.
Each MAPPING is (ASCII-CHAR UNICODE-CHAR DESCRIPTION); DESCRIPTION documents the
fact at compile time and is not retained at runtime."
  `(defun %dec-graphics-char (ch)
     "Map CH from DEC special graphics to Unicode, or return CH unchanged."
     (case ch
       ,@(mapcar
          (lambda (mapping)
            `(,(first mapping) ,(second mapping)))
          mappings)
       (t ch))))

(define-dec-graphics-table (#\j #\┘ "lower-right corner")
                           (#\k #\┐ "upper-right corner")
                           (#\l #\┌ "upper-left corner")
                           (#\m #\└ "lower-left corner")
                           (#\n #\┼ "crossing")
                           (#\t #\├ "left tee")
                           (#\u #\┤ "right tee")
                           (#\v #\┴ "bottom tee")
                           (#\w #\┬ "top tee")
                           (#\x #\│ "vertical line")
                           (#\o #\⎺ "scan line 1 (top)")
                           (#\p #\⎻ "scan line 3")
                           (#\q #\─ "scan line 5 / horizontal line")
                           (#\r #\⎼ "scan line 7")
                           (#\s #\⎽ "scan line 9 (bottom)")
                           (#\a #\▒ "checkerboard")
                           (#\` #\◆ "diamond")
                           (#\f #\° "degree symbol")
                           (#\g #\± "plus-minus")
                           (#\y #\≤ "less-than-or-equal")
                           (#\z #\≥ "greater-than-or-equal")
                           (#\{ #\π "pi")
                           (#\| #\≠ "not-equal")
                           (#\} #\£ "UK pound sign")
                           (#\~ #\· "centred dot / bullet")
                           (#\_ #\Space "blank")
                           (#\b #\␉ "horizontal tab (HT)")
                           (#\c #\␌ "form feed (FF)")
                           (#\d #\␍ "carriage return (CR)")
                           (#\e #\␊ "line feed (LF)")
                           (#\h #\␤ "newline (NL)")
                           (#\i #\␋ "vertical tab (VT)"))

(defun %control-char-p (ch)
  "Return true when CH is a C0 or C1 control code point."
  (let ((codepoint (char-code ch)))
    (or (< codepoint #x20) (<= #x7F codepoint #x9F))))

(defun combining-char-p (ch)
  "Return true when CH is a printable zero-width combining character.
Controls are excluded because their zero width means that they are commands,
not members of the preceding grapheme cluster."
  (and (not (%control-char-p ch)) (zerop (char-width ch))))

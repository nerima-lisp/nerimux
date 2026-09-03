(in-package #:nerimux/test/terminal)

(describe "terminal-suite/place-wide-char-suite"

  (it "place-wide-char-writes-lead-and-continuation"
    (with-screen (s 10 5)
      (nerimux/terminal/actions::%place-wide-char s 0 0 #\中 7 0 0 0 0 nil)
      (let ((lead (screen-cell s 0 0))
            (cont (screen-cell s 1 0)))
        (expect (char= #\中 (cell-char lead)))
        (expect (= 2 (cell-width lead)))
        (expect (= 0 (cell-width cont))))))

  (it "place-wide-char-at-last-column-no-continuation"
    (with-screen (s 5 5)
      (nerimux/terminal/actions::%place-wide-char s 4 0 #\中 7 0 0 0 0 nil)
      (let ((lead (screen-cell s 4 0)))
        (expect (char= #\中 (cell-char lead)))
        (expect (= 2 (cell-width lead)))))))

(describe "terminal-suite/cursor-movement-table-suite"

  (it "cursor-movements-single-step-table"
    (let ((cases '((5 5 up    1 5 4)
                   (5 5 down  1 5 6)
                   (5 5 left  1 4 5)
                   (5 5 right 1 6 5))))
      (dolist (c cases)
        (destructuring-bind (sx sy dir n ex ey) c
          (with-screen (s 10 10)
            (setf (nerimux/terminal/types:screen-cursor-x s) sx
                  (nerimux/terminal/types:screen-cursor-y s) sy)
            (ecase dir
              (up    (nerimux/terminal/actions:cursor-up    s n))
              (down  (nerimux/terminal/actions:cursor-down  s n))
              (left  (nerimux/terminal/actions:cursor-left  s n))
              (right (nerimux/terminal/actions:cursor-right s n)))
            (expect (= ex (screen-cursor-x s)))
            (expect (= ey (screen-cursor-y s)))))))))

(describe "terminal-suite/combining-char-p-suite"

  (it "combining-char-p-returns-true-for-combining-diacritical-marks"
    (expect (nerimux/terminal/actions:combining-char-p (code-char #x0300)))
    (expect (nerimux/terminal/actions:combining-char-p (code-char #x036F))))

  (it "combining-char-p-returns-true-for-combining-half-marks"
    (expect (nerimux/terminal/actions:combining-char-p (code-char #xFE20)))
    (expect (nerimux/terminal/actions:combining-char-p (code-char #xFE2F))))

  (it "combining-char-p-returns-false-for-ascii-printable"
    (expect (nerimux/terminal/actions:combining-char-p #\A) :to-be-falsy)
    (expect (nerimux/terminal/actions:combining-char-p #\Space) :to-be-falsy)
    (expect (nerimux/terminal/actions:combining-char-p #\Null) :to-be-falsy))

  (it-each ((#x0300 t   "combining grave accent - Diacritical Marks start")
            (#x036F t   "combining latin small letter x - Diacritical Marks end")
            (#x0370 nil "greek capital letter Heta - just after Diacritical Marks")
            (#x1AB0 t   "combining doubled circumflex accent - Extended start")
            (#x1AFF nil "unassigned tail of the Extended block - one column")
            (#x20D0 t   "combining left harpoon above - Marks for Symbols start")
            (#x20F0 t   "combining asterisk above - last assigned Marks for Symbols")
            (#x20FF nil "unassigned tail of the Marks for Symbols block - one column")
            (#x0041 nil "ASCII A - not a combining character"))
      "combining-char-p: ~*~*~A"
      (cp expected description)
    (declare (ignore description))
    (let ((ch (code-char cp)))
      (if expected
          (expect (nerimux/terminal/actions:combining-char-p ch))
          (expect (nerimux/terminal/actions:combining-char-p ch) :to-be-falsy)))))

(describe "terminal-suite/write-char-combining-suite"

  (it "write-char-at-cursor-combining-does-not-advance-cursor"
    (with-screen (s 10 5)
      (feed s "a")                          ; cursor at col 1
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x0301))
      (check-cursor s 1 0)))

  (it "write-char-at-cursor-combining-appended-to-cell"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:write-char-at-cursor s #\a)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x0301))
      (let ((cell (screen-cell s 0 0)))
        (expect (char= #\a (cell-char cell)))
        (expect (member (code-char #x0301)
                        (nerimux/terminal/types:cell-combining cell))))))

  (it "write-char-at-cursor-combining-at-col-zero-uses-col-zero"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x0300))
      (check-cursor s 0 0)
      (expect (nerimux/terminal/types:screen-dirty-p s)))))

(describe "terminal-suite/dec-graphics-suite"

  (it "set-charset-dec-graphics-remaps-box-drawing"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (nerimux/terminal/actions:write-char-at-cursor s #\j)
      (expect (char= #\┘ (char-at s 0 0)))))

  (it "set-charset-dec-graphics-remaps-horizontal-line"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (nerimux/terminal/actions:write-char-at-cursor s #\q)
      (expect (char= #\─ (char-at s 0 0)))))

  (it "set-charset-ascii-no-remapping"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :ascii)
      (nerimux/terminal/actions:write-char-at-cursor s #\j)
      (expect (char= #\j (char-at s 0 0)))))

  (it-each ((#\j #\┘ "lower-right corner")
            (#\k #\┐ "upper-right corner")
            (#\l #\┌ "upper-left corner")
            (#\m #\└ "lower-left corner")
            (#\n #\┼ "crossing")
            (#\t #\├ "left tee")
            (#\u #\┤ "right tee")
            (#\v #\┴ "bottom tee")
            (#\w #\┬ "top tee")
            (#\q #\─ "horizontal line")
            (#\x #\│ "vertical line")
            (#\a #\▒ "checkerboard")
            (#\` #\◆ "diamond")
            (#\y #\≤ "less-than-or-equal")
            (#\z #\≥ "greater-than-or-equal")
            (#\{ #\π "pi")
            (#\| #\≠ "not-equal")
            (#\} #\£ "UK pound sign")
            (#\~ #\· "centred dot")
            (#\o #\⎺ "scan line 1")
            (#\s #\⎽ "scan line 9"))
      "set-charset-dec-graphics: ~*~*~A"
      (in expected desc)
    (declare (ignore desc))
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (nerimux/terminal/actions:write-char-at-cursor s in)
      (expect (char= expected (char-at s 0 0)))))

  (it "set-charset-dec-graphics-unmapped-char-passes-through"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (nerimux/terminal/actions:write-char-at-cursor s #\5)
      (expect (char= #\5 (char-at s 0 0)))))

  (it "dec-graphics-activated-via-esc-sequence"
    (with-screen (s 10 5)
      (feed s (esc "(0"))
      (feed s "j")
      (expect (char= #\┘ (char-at s 0 0)))))

  (it "dec-graphics-deactivated-via-esc-sequence"
    (with-screen (s 10 5)
      (feed s (esc "(0"))   ; enable DEC graphics
      (feed s (esc "(B"))   ; restore ASCII
      (feed s "j")          ; now plain ASCII 'j'
      (expect (char= #\j (char-at s 0 0))))))

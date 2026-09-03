(in-package #:nerimux/test/terminal)

(declaim (notinline nerimux/terminal/types:clamp
                    nerimux/terminal/types:char-width))

(describe "terminal-suite/attr-constants"

  (it "attr-bit-values-table"
    (check-table (list (list #b00000001 nerimux/terminal/types:+attr-bold+              "bold is bit 0")
                       (list #b00000010 nerimux/terminal/types:+attr-dim+               "dim is bit 1")
                       (list #b00000100 nerimux/terminal/types:+attr-reverse+           "reverse is bit 2")
                       (list #b00001000 nerimux/terminal/types:+attr-underline+         "underline is bit 3")
                       (list #b00010000 nerimux/terminal/types:+attr-blink+             "blink is bit 4")
                       (list #b00100000 nerimux/terminal/types:+attr-italic+            "italic is bit 5")
                       (list #b01000000 nerimux/terminal/types:+attr-conceal+           "conceal is bit 6")
                       (list #b10000000 nerimux/terminal/types:+attr-strikethrough+     "strikethrough is bit 7")
                       (list #b00000001 nerimux/terminal/types:+attr2-double-underline+ "double-underline is attrs2 bit 0")
                       (list #b00000010 nerimux/terminal/types:+attr2-overline+         "overline is attrs2 bit 1"))
                 :test #'equal))

  (it "attr-constants-are-distinct-single-bits"
    (let ((constants (list nerimux/terminal/types:+attr-bold+
                           nerimux/terminal/types:+attr-dim+
                           nerimux/terminal/types:+attr-reverse+
                           nerimux/terminal/types:+attr-underline+
                           nerimux/terminal/types:+attr-blink+
                           nerimux/terminal/types:+attr-italic+
                           nerimux/terminal/types:+attr-conceal+
                           nerimux/terminal/types:+attr-strikethrough+)))
      (expect (= 8 (length (remove-duplicates constants))))
      (expect (every #'(lambda (c) (= 1 (logcount c))) constants)))))

(describe "terminal-suite/cell-struct"

  (it "make-cell-default-slots"
    (let ((c (nerimux/terminal/types:make-cell)))
      (expect (char= #\Space (cell-char c)))
      (check-table (list (list (cell-fg   c)                             nerimux/terminal/types:+default-color+ "default fg must be the default-colour sentinel")
                         (list (cell-bg   c)                             nerimux/terminal/types:+default-color+ "default bg must be the default-colour sentinel")
                         (list (cell-attrs c)                            0 "default attrs must be 0")
                         (list (nerimux/terminal/types:cell-attrs2    c) 0 "default attrs2 must be 0")
                         (list (nerimux/terminal/types:cell-ul-color  c) 0 "default ul-color must be 0")
                         (list (cell-width c)                            1 "default width must be 1"))
                   :test #'equal)
      (expect (null (nerimux/terminal/types:cell-combining c)))))

  (it "make-cell-custom-slots"
    (let ((c (nerimux/terminal/types:make-cell :char #\A :fg 2 :bg 5 :attrs 3
                                                :attrs2 1 :ul-color 4 :width 2)))
      (expect (char= #\A (cell-char c)))
      (check-table (list (list (cell-fg   c)                            2 "fg")
                         (list (cell-bg   c)                            5 "bg")
                         (list (cell-attrs c)                           3 "attrs")
                         (list (nerimux/terminal/types:cell-attrs2   c) 1 "attrs2")
                         (list (nerimux/terminal/types:cell-ul-color c) 4 "ul-color")
                         (list (cell-width c)                           2 "width"))
                   :test #'equal)))

  (it "make-cell-continuation-width-zero"
    (let ((c (nerimux/terminal/types:make-cell :char #\Space :width 0)))
      (expect (= 0 (cell-width c)))))

  (it "cell-p-returns-true-for-cell"
    (let ((c (nerimux/terminal/types:make-cell)))
      (expect (nerimux/terminal/types:cell-p c) :to-be-truthy)))

  (it "cell-p-returns-false-for-non-cell"
    (expect (nerimux/terminal/types:cell-p 42) :to-be-falsy)
    (expect (nerimux/terminal/types:cell-p "hello") :to-be-falsy)
    (expect (nerimux/terminal/types:cell-p nil) :to-be-falsy))

  (it "make-cell-combining-slot"
    (let ((c (nerimux/terminal/types:make-cell
              :combining (list (code-char #x0300) (code-char #x0301)))))
      (expect (= 2 (length (nerimux/terminal/types:cell-combining c))))))

  (it "blank-cell-returns-default-cell"
    (let ((c (nerimux/terminal/types:blank-cell)))
      (expect (char= #\Space (cell-char c)))
      (check-table (list (list (cell-fg    c) nerimux/terminal/types:+default-color+ "blank-cell fg must be the default-colour sentinel")
                         (list (cell-bg    c) nerimux/terminal/types:+default-color+ "blank-cell bg must be the default-colour sentinel")
                         (list (cell-attrs c) 0 "blank-cell attrs must be 0")
                         (list (cell-width c) 1 "blank-cell width must be 1"))
                   :test #'equal)))

  (it "blank-cell-returns-fresh-instance-each-call"
    (let ((c1 (nerimux/terminal/types:blank-cell))
          (c2 (nerimux/terminal/types:blank-cell)))
      (expect (not (eq c1 c2))))))

(describe "terminal-suite/make-blank-cells-suite"

  (it "make-blank-cells-returns-simple-vector-of-correct-length"
    (let ((v (nerimux/terminal/types:%make-blank-cells 10)))
      (expect (simple-vector-p v))
      (expect (= 10 (length v)))))

  (it "make-blank-cells-all-elements-are-blank"
    (let ((v (nerimux/terminal/types:%make-blank-cells 5)))
      (dotimes (i 5)
        (let ((c (aref v i)))
          (expect (nerimux/terminal/types:cell-p c))
          (expect (char= #\Space (cell-char c)))
          (expect (= nerimux/terminal/types:+default-color+ (cell-fg c)))
          (expect (= nerimux/terminal/types:+default-color+ (cell-bg c)))
          (expect (= 1 (cell-width c)))))))

  (it "make-blank-cells-zero-length-returns-empty-vector"
    (let ((v (nerimux/terminal/types:%make-blank-cells 0)))
      (expect (simple-vector-p v))
      (expect (= 0 (length v))))))

(describe "terminal-suite/clamp-suite"

  (it "clamp-table"
    (dolist (case '((-5  0 10  0  "below lo clamps to lo")
                    ( 1  3  9  3  "below lo clamps to lo (3..9)")
                    (99  0 10 10  "above hi clamps to hi")
                    (20  3  9  9  "above hi clamps to hi (3..9)")
                    ( 5  0 10  5  "within range returned unchanged")
                    ( 0  0 10  0  "at lo boundary returned unchanged")
                    (10  0 10 10  "at hi boundary returned unchanged")
                    ( 0  7  7  7  "lo=hi, v below: always returns lo/hi")
                    ( 7  7  7  7  "lo=hi, v equal: always returns lo/hi")
                    (99  7  7  7  "lo=hi, v above: always returns lo/hi")))
      (destructuring-bind (v lo hi expected desc) case
        (declare (ignore desc))
        (expect (= expected (nerimux/terminal/types:clamp v lo hi)))))))

(describe "terminal-suite/safe-code-char-suite"

  (it "safe-code-char-valid-codepoint"
    (expect (char= #\A (nerimux/terminal/types:safe-code-char 65)))
    (expect (char= #\a (nerimux/terminal/types:safe-code-char 97))))

  (it "safe-code-char-zero-returns-null-char"
    (expect (= 0 (char-code (nerimux/terminal/types:safe-code-char 0)))))

  (it "safe-code-char-invalid-codepoint-returns-replacement"
    (let ((replacement (nerimux/terminal/types:safe-code-char
                        (+ char-code-limit 1))))
      (expect (= #xFFFD (char-code replacement)))))

  (it "safe-code-char-table"
    (check-table (list (list (nerimux/terminal/types:safe-code-char 65) #\A    "U+0041 = LATIN CAPITAL LETTER A")
                       (list (nerimux/terminal/types:safe-code-char 97) #\a    "U+0061 = LATIN SMALL LETTER A")
                       (list (nerimux/terminal/types:safe-code-char 32) #\Space "U+0020 = SPACE")
                       (list (nerimux/terminal/types:safe-code-char 10) #\Newline "U+000A = LINE FEED"))
                 :test #'equal))


  (it "surrogate-code-point-p-covers-exactly-the-surrogate-block"
    (expect (nerimux/terminal/types:surrogate-code-point-p #xD800) :to-be-truthy)
    (expect (nerimux/terminal/types:surrogate-code-point-p #xDBFF) :to-be-truthy)
    (expect (nerimux/terminal/types:surrogate-code-point-p #xDC00) :to-be-truthy)
    (expect (nerimux/terminal/types:surrogate-code-point-p #xDFFF) :to-be-truthy)
    (expect (nerimux/terminal/types:surrogate-code-point-p #xD7FF) :to-be-falsy)
    (expect (nerimux/terminal/types:surrogate-code-point-p #xE000) :to-be-falsy))

  (it "safe-code-char-lone-surrogate-returns-replacement"
    (dolist (cp '(#xD800 #xDBFF #xDC00 #xDFFF))
      (expect (= #xFFFD (char-code (nerimux/terminal/types:safe-code-char cp)))))
    (expect (= #xD7FF (char-code (nerimux/terminal/types:safe-code-char #xD7FF))))
    (expect (= #xE000 (char-code (nerimux/terminal/types:safe-code-char #xE000)))))

  (it "safe-code-char-result-is-always-utf8-encodable"
    (dolist (cp '(#xD800 #xDBFF #xDFFF #x41 #xD7FF #xE000 #x1F600))
      (let ((string (string (nerimux/terminal/types:safe-code-char cp))))
        (expect (cl-codec-kit:string-to-octets string :encoding :utf-8)
                :to-be-truthy)))))

(describe "terminal-suite/double-width"

  (it "char-width-classification"
    (check-table (list (list (char-width #\a)     1 "ASCII a is single-width")
                       (list (char-width #\Space) 1 "Space is single-width")
                       (list (char-width #\あ)    2 "Hiragana is double-width")
                       (list (char-width #\中)    2 "CJK ideograph is double-width")
                       (list (char-width #\│)     1 "box drawing stays single-width"))
                 :test #'equal))

  (it "char-width-ascii-range-is-single"
    (loop for cp from 32 to 126
          do (expect (= 1 (char-width (code-char cp))))))

  (it "char-width-combining-marks-are-zero-columns"
    (dolist (cp '(#x0300      ; COMBINING GRAVE ACCENT (Mn)
                  #x0301      ; COMBINING ACUTE ACCENT (Mn)
                  #x036F      ; COMBINING LATIN SMALL LETTER X (Mn), block end
                  #x1AB0      ; COMBINING DOUBLED CIRCUMFLEX ACCENT (Mn)
                  #x1DC0      ; COMBINING DOTTED GRAVE ACCENT (Mn)
                  #x20D0      ; COMBINING LEFT HARPOON ABOVE (Mn)
                  #x20DD      ; COMBINING ENCLOSING CIRCLE (Me)
                  #xFE20))    ; COMBINING LIGATURE LEFT HALF (Mn)
      (expect (= 0 (char-width (code-char cp))))))

  (it "char-width-kana-combining-marks-are-zero-not-two"
    (expect (= 0 (char-width (code-char #x3099))))
    (expect (= 0 (char-width (code-char #x309A)))))

  (it "char-width-wide-symbol-outside-old-emoji-range"
    (expect (= 2 (char-width (code-char #x231A)))))

  (it "char-width-range-boundaries-table"
    (dolist (case `((#x1100 2 "U+1100 Hangul Jamo start")
                    (#x115F 2 "U+115F Hangul Jamo end")
                    (#x2E80 2 "U+2E80 CJK Radicals start")
                    (#x303E 2 "U+303E CJK Radicals end")
                    (#x3041 2 "U+3041 Hiragana start")
                    (#x33FF 2 "U+33FF CJK compat end")
                    (#x3400 2 "U+3400 CJK Extension A start")
                    (#x4DBF 2 "U+4DBF CJK Extension A end")
                    (#x4E00 2 "U+4E00 CJK Unified start")
                    (#x9FFF 2 "U+9FFF CJK Unified end")
                    (#xAC00 2 "U+AC00 Hangul syllables start")
                    (#xD7A3 2 "U+D7A3 Hangul syllables end")
                    (#xFF00 1 "U+FF00 unassigned, below Fullwidth block — width 1")
                    (#xFF01 2 "U+FF01 Fullwidth exclamation, real block start")
                    (#xFF21 2 "U+FF21 Fullwidth Latin Capital A (mid-range)")
                    (#xFF60 2 "U+FF60 Fullwidth ASCII end")
                    (#xFFE0 2 "U+FFE0 Fullwidth signs start")
                    (#xFFE6 2 "U+FFE6 Fullwidth signs end")
                    (#x1F2FF 1 "U+1F2FF below Emoji block — must be width 1")
                    (#x1F300 2 "U+1F300 Emoji/pictograph block start")
                    (#x1FAFF 1 "U+1FAFF unassigned — width 1, not 2")
                    (#x1F600 2 "U+1F600 GRINNING FACE, a real wide emoji")
                    (#x20000 2 "U+20000 CJK Extension B start")))
      (destructuring-bind (cp expected-width desc) case
        (declare (ignore desc))
        (when (< cp char-code-limit)
          (expect (= expected-width (char-width (code-char cp))))))))


  (it "wide-char-occupies-two-columns"
    (with-screen (s 10 2)
      (utf8-feed s "あ")
      (expect (char= #\あ (char-at s 0 0)))
      (expect (= 2 (cell-width (cell-at s 0 0))))
      (expect (= 0 (cell-width (cell-at s 1 0))))
      (check-cursor s 2 0)))

  (it "wide-char-wraps-at-right-edge"
    (with-screen (s 3 2)
      (feed s "ab")            ; cursor at column 2 (last column of a 3-wide screen)
      (utf8-feed s "あ")       ; cannot fit one column -> wraps to row 1
      (expect (char= #\a  (char-at s 0 0)))
      (expect (char= #\b  (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\あ (char-at s 0 1)))
      (check-cursor s 2 1))))

(describe "terminal-suite/cell-combining-chars"

  (it "combining-char-p-diacritic-marks-return-true"
    (expect (nerimux/terminal/actions:combining-char-p (code-char #x0300)) :to-be-truthy)
    (expect (nerimux/terminal/actions:combining-char-p (code-char #x036F)) :to-be-truthy))

  (it "combining-char-p-ascii-returns-false"
    (expect (nerimux/terminal/actions:combining-char-p #\a) :to-be-falsy)
    (expect (nerimux/terminal/actions:combining-char-p #\Space) :to-be-falsy))

  (it "combining-char-p-half-marks-return-true"
    (expect (nerimux/terminal/actions:combining-char-p (code-char #xFE20)) :to-be-truthy))

  (it "write-char-at-cursor-combining-char-appended-not-advanced"
    (with-screen (s 10 5)
      (feed s "a")                        ; base character at col 0; cursor now at col 1
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x0300))
      (check-cursor s 1 0)
      (let ((combining (nerimux/terminal/types:cell-combining (cell-at s 0 0))))
        (expect (member (code-char #x0300) combining)))))

  (it "write-char-at-cursor-combining-at-col-zero-appended-to-col-zero"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x0301))
      (check-cursor s 0 0)
      (expect (member (code-char #x0301) (nerimux/terminal/types:cell-combining (cell-at s 0 0)))))))

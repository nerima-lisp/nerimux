(in-package #:nerimux/test/terminal)

(describe "terminal-suite/combining-char-p-agrees-with-char-width"

  (it-each ((#x3099 0 "U+3099 combining katakana-hiragana voiced sound mark")
            (#x309A 0 "U+309A combining katakana-hiragana semi-voiced sound mark")
            (#x0301 0 "U+0301 combining acute accent")
            (#x0902 0 "U+0902 devanagari sign anusvara")
            (#xFE0F 0 "U+FE0F variation selector-16")
            (#x20DD 0 "U+20DD combining enclosing circle (Me)")
            (#x1160 0 "U+1160 hangul jungseong filler")
            (#x200D 0 "U+200D zero width joiner (Cf)")
            (#x200B 0 "U+200B zero width space (Cf)")
            (#x200C 0 "U+200C zero width non-joiner (Cf)")
            (#xFEFF 0 "U+FEFF zero width no-break space (Cf)")
            (#x00AD 1 "U+00AD soft hyphen - the Cf that keeps its column")
            (#x1AFF 1 "U+1AFF unassigned (Cn)")
            (#x20FF 1 "U+20FF unassigned (Cn)")
            (#x0041 1 "A")
            (#x304B 2 "U+304B hiragana ka")
            (#x304C 2 "U+304C hiragana ga")
            (#x65E5 2 "U+65E5 CJK ideograph")
            (#x1F600 2 "U+1F600 grinning face"))
      "combining-char-p agrees with char-width: ~*~*~A"
      (cp width description)
    (declare (ignore description))
    (let ((ch (code-char cp)))
      (expect (= width (char-width ch)))
      (if (zerop width)
          (expect (nerimux/terminal/actions:combining-char-p ch))
          (expect (nerimux/terminal/actions:combining-char-p ch) :to-be-falsy)))))

(describe "terminal-suite/kana-sound-mark-combining"

  (it "kana-sound-mark-does-not-advance-the-cursor"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x304B)) ; か
      (check-cursor s 2 0)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x3099))
      (check-cursor s 2 0)))

  (it "kana-plus-voiced-mark-occupies-the-same-cells-as-precomposed"
    (with-screen (composed 10 5)
      (with-screen (decomposed 10 5)
        (utf8-feed composed   (string (code-char #x304C)))                ; が
        (utf8-feed decomposed (coerce (list (code-char #x304B)            ; か
                                            (code-char #x3099))
                                      'string))
        (expect (= (screen-cursor-x composed) (screen-cursor-x decomposed)))
        (expect (= 2 (screen-cursor-x decomposed)))
        (expect (= (cell-width (screen-cell composed   0 0))
                   (cell-width (screen-cell decomposed 0 0))))
        (expect (= (cell-width (screen-cell composed   1 0))
                   (cell-width (screen-cell decomposed 1 0))))
        (expect (= 2 (cell-width (screen-cell decomposed 0 0))))
        (expect (= 0 (cell-width (screen-cell decomposed 1 0)))))))

  (it "kana-sound-mark-attaches-to-the-lead-cell-not-the-continuation"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list (code-char #x304B) (code-char #x3099)) 'string))
      (let ((lead (screen-cell s 0 0))
            (cont (screen-cell s 1 0)))
        (expect (char= (code-char #x304B) (cell-char lead)))
        (expect (member (code-char #x3099)
                        (nerimux/terminal/types:cell-combining lead)))
        (expect (null (nerimux/terminal/types:cell-combining cont))))))

  (it "kana-semi-voiced-mark-attaches-to-the-lead-cell"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list (code-char #x306F)  ; は
                                 (code-char #x309A))
                           'string))
      (check-cursor s 2 0)
      (expect (member (code-char #x309A)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

(describe "terminal-suite/plain-combining-mark-unchanged"

  (it "acute-accent-attaches-to-single-width-base"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\e (code-char #x0301)) 'string))
      (check-cursor s 1 0)
      (let ((cell (screen-cell s 0 0)))
        (expect (char= #\e (cell-char cell)))
        (expect (= 1 (cell-width cell)))
        (expect (member (code-char #x0301)
                        (nerimux/terminal/types:cell-combining cell))))))

  (it "stacked-combining-marks-accumulate-in-order"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char #x0301) (code-char #x0308)) 'string))
      (check-cursor s 1 0)
      (expect (equal (list (code-char #x0301) (code-char #x0308))
                     (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

(describe "terminal-suite/format-characters-combine"

  (it "zwj-combines-rather-than-taking-a-column"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char #x200D)) 'string))
      (check-cursor s 1 0)
      (expect (member (code-char #x200D)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0))))))

  (it "emoji-zwj-sequence-costs-no-extra-column"
    (with-screen (s 20 5)
      (utf8-feed s (coerce (list (code-char #x1F468)   ; man
                                 (code-char #x200D)
                                 (code-char #x1F469))  ; woman
                           'string))
      (check-cursor s 4 0)
      (expect (member (code-char #x200D)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0))))))

  (it-each ((#x200B "zero width space")
            (#x200C "zero width non-joiner")
            (#xFEFF "zero width no-break space")
            (#x20DD "combining enclosing circle (Me)")
            (#x1160 "hangul jungseong filler"))
      "zero-width character combines: ~*~A"
      (cp description)
    (declare (ignore description))
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char cp)) 'string))
      (check-cursor s 1 0)
      (expect (member (code-char cp)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0))))))

  (it "soft-hyphen-is-not-combining"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/actions:combining-char-p (code-char #x00AD))
              :to-be-falsy)
      (utf8-feed s (coerce (list #\a (code-char #x00AD)) 'string))
      (check-cursor s 2 0)
      (expect (null (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

(describe "terminal-suite/control-codes-not-combining"

  (it-each ((#x0000 "NUL")
            (#x0009 "TAB")
            (#x000A "LF")
            (#x001B "ESC")
            (#x001F "US - last C0")
            (#x007F "DEL")
            (#x0080 "U+0080 - first C1")
            (#x009F "U+009F - last C1"))
      "control code is zero-width but not combining: ~*~A"
      (cp description)
    (declare (ignore description))
    (let ((ch (code-char cp)))
      (expect (= 0 (char-width ch)))
      (expect (nerimux/terminal/actions:combining-char-p ch) :to-be-falsy)))

  (it "c1-control-from-utf8-decoder-does-not-attach-to-previous-cell"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char #x0080)) 'string))
      (let ((cell (screen-cell s 0 0)))
        (expect (char= #\a (cell-char cell)))
        (expect (null (nerimux/terminal/types:cell-combining cell))))
      (expect (= 2 (screen-cursor-x s)))))

  (it "c0-tab-byte-drives-its-own-action-not-a-combine"
    (with-screen (s 20 5)
      (feed s (format nil "a~C" #\Tab))
      (check-cursor s 8 0)
      (expect (null (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

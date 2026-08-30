(in-package #:nerimux/test/terminal)

;;;; char-write tests (src/domain/terminal/char-write.lisp).
;;;;
;;;; Pins the definition of COMBINING-CHAR-P: a character combines exactly when
;;;; CL-TTY-KIT:CHAR-WIDTH says it occupies zero columns, minus control codes.
;;;; Before that unification the predicate was a hand-written list of five
;;;; ranges and disagreed with CHAR-WIDTH in both directions — see the
;;;; commentary above COMBINING-CHAR-P.
;;;;
;;;; The predicate's five-range era is also covered by cursor-tests-b.lisp
;;;; (terminal-suite/combining-char-p-suite); this file adds the cases the range
;;;; list got wrong and the decisions the new definition makes.

;;; ── SUITE: combining-char-p agrees with char-width ──────────────────────────
;;;
;;; The invariant, stated once: for every NON-CONTROL code point,
;;;   (combining-char-p ch)  <=>  (zerop (char-width ch))
;;; Control codes are the one deliberate exception and get their own suite.

(describe "terminal-suite/combining-char-p-agrees-with-char-width"

  ;; Every non-control code point: predicate and width must not contradict.
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
      ;; The stated width is what CL-TTY-KIT:CHAR-WIDTH actually returns.
      (expect (= width (char-width ch)))
      ;; And the predicate is that width being zero — nothing else.
      (if (zerop width)
          (expect (nerimux/terminal/actions:combining-char-p ch))
          (expect (nerimux/terminal/actions:combining-char-p ch) :to-be-falsy)))))

;;; ── SUITE: U+3099 / U+309A — the defect this file exists for ────────────────
;;;
;;; The two kana sound marks were missing from the old range list.  The old
;;; hand-rolled width table counted them as 2 columns; CHAR-WIDTH now correctly
;;; says 0, but the writer still gave them a cell of their own for 1.  Three
;;; different answers to one question, worth up to three cells of drift.
;;;
;;; か + U+3099 must land on exactly the cells が lands on.

(describe "terminal-suite/kana-sound-mark-combining"

  ;; The marks contribute no columns: the cursor does not move past the base.
  (it "kana-sound-mark-does-not-advance-the-cursor"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x304B)) ; か
      (check-cursor s 2 0)
      (nerimux/terminal/actions:write-char-at-cursor s (code-char #x3099))
      (check-cursor s 2 0)))

  ;; か + U+3099 occupies the same cells as the precomposed が.
  (it "kana-plus-voiced-mark-occupies-the-same-cells-as-precomposed"
    (with-screen (composed 10 5)
      (with-screen (decomposed 10 5)
        (utf8-feed composed   (string (code-char #x304C)))                ; が
        (utf8-feed decomposed (coerce (list (code-char #x304B)            ; か
                                            (code-char #x3099))
                                      'string))
        ;; Same cursor column: two columns consumed, not three.
        (expect (= (screen-cursor-x composed) (screen-cursor-x decomposed)))
        (expect (= 2 (screen-cursor-x decomposed)))
        ;; Same cell geometry: a width-2 lead plus a width-0 continuation.
        (expect (= (cell-width (screen-cell composed   0 0))
                   (cell-width (screen-cell decomposed 0 0))))
        (expect (= (cell-width (screen-cell composed   1 0))
                   (cell-width (screen-cell decomposed 1 0))))
        (expect (= 2 (cell-width (screen-cell decomposed 0 0))))
        (expect (= 0 (cell-width (screen-cell decomposed 1 0)))))))

  ;; The mark attaches to the wide character's LEAD cell, not to its width-0
  ;; continuation placeholder.  %render-cell-row emits nothing for a width-0
  ;; cell — the outer terminal already drew both columns of the glyph to its
  ;; left — so a mark parked on the placeholder would never be rendered.
  (it "kana-sound-mark-attaches-to-the-lead-cell-not-the-continuation"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list (code-char #x304B) (code-char #x3099)) 'string))
      (let ((lead (screen-cell s 0 0))
            (cont (screen-cell s 1 0)))
        (expect (char= (code-char #x304B) (cell-char lead)))
        (expect (member (code-char #x3099)
                        (nerimux/terminal/types:cell-combining lead)))
        (expect (null (nerimux/terminal/types:cell-combining cont))))))

  ;; The semi-voiced mark behaves identically: は + U+309A reads as ぱ's cells.
  (it "kana-semi-voiced-mark-attaches-to-the-lead-cell"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list (code-char #x306F)  ; は
                                 (code-char #x309A))
                           'string))
      (check-cursor s 2 0)
      (expect (member (code-char #x309A)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

;;; ── SUITE: a plain combining mark still behaves ─────────────────────────────
;;;
;;; U+0301 was already handled by the old range list.  Widening the definition
;;; must not disturb it: it still attaches to the single-width cell on its left
;;; and still leaves the cursor alone.

(describe "terminal-suite/plain-combining-mark-unchanged"

  ;; e + U+0301 stays on one cell and one column.
  (it "acute-accent-attaches-to-single-width-base"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\e (code-char #x0301)) 'string))
      (check-cursor s 1 0)
      (let ((cell (screen-cell s 0 0)))
        (expect (char= #\e (cell-char cell)))
        (expect (= 1 (cell-width cell)))
        (expect (member (code-char #x0301)
                        (nerimux/terminal/types:cell-combining cell))))))

  ;; Several marks stack on one base, in the order they arrived.
  (it "stacked-combining-marks-accumulate-in-order"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char #x0301) (code-char #x0308)) 'string))
      (check-cursor s 1 0)
      (expect (equal (list (code-char #x0301) (code-char #x0308))
                     (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

;;; ── SUITE: Cf format characters combine (the decision, pinned) ──────────────
;;;
;;; DECISION: ZWJ and the other Cf format controls COMBINE rather than taking a
;;; column of their own.  CHAR-WIDTH reports 0 for them, tmux's own rule is
;;; "width 0 -> screen_write_combine", and a terminal that gave ZWJ a column
;;; would push every emoji ZWJ sequence one cell to the right.
;;;
;;; If this is ever reversed, these tests are the place it must be argued.

(describe "terminal-suite/format-characters-combine"

  ;; ZWJ takes no column and attaches to the character before it.
  (it "zwj-combines-rather-than-taking-a-column"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char #x200D)) 'string))
      (check-cursor s 1 0)
      (expect (member (code-char #x200D)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0))))))

  ;; An emoji ZWJ sequence costs only its glyphs: 2 + 0 + 2 columns, never 5.
  (it "emoji-zwj-sequence-costs-no-extra-column"
    (with-screen (s 20 5)
      (utf8-feed s (coerce (list (code-char #x1F468)   ; man
                                 (code-char #x200D)
                                 (code-char #x1F469))  ; woman
                           'string))
      (check-cursor s 4 0)
      (expect (member (code-char #x200D)
                      (nerimux/terminal/types:cell-combining (screen-cell s 0 0))))))

  ;; The other zero-width format controls take the same path.
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

  ;; U+00AD SOFT HYPHEN is the Cf that CHAR-WIDTH exempts: it keeps its column.
  (it "soft-hyphen-is-not-combining"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/actions:combining-char-p (code-char #x00AD))
              :to-be-falsy)
      (utf8-feed s (coerce (list #\a (code-char #x00AD)) 'string))
      (check-cursor s 2 0)
      (expect (null (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

;;; ── SUITE: control codes are NOT combining ──────────────────────────────────
;;;
;;; CHAR-WIDTH answers 0 for every C0 and C1 code point because they are not
;;; printed, NOT because they attach to the character before them.  The parser
;;; dispatches C0 bytes on a separate path and never hands one to
;;; WRITE-CHAR-AT-CURSOR — but a C1 control DOES arrive, through the UTF-8
;;; decoder: the byte pair C2 80 assembles into U+0080 and reaches
;;; WRITE-CODEPOINT.  So this is a guard in COMBINING-CHAR-P, not an accident
;;; of the call graph.

(describe "terminal-suite/control-codes-not-combining"

  ;; Control codes are zero-width to CHAR-WIDTH and still not combining.
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
      ;; The width really is 0 — this is exactly the trap the guard exists for.
      (expect (= 0 (char-width ch)))
      (expect (nerimux/terminal/actions:combining-char-p ch) :to-be-falsy)))

  ;; The C1 control that actually reaches WRITE-CODEPOINT: feeding C2 80 after a
  ;; base character must not glue U+0080 onto that character's cell.
  (it "c1-control-from-utf8-decoder-does-not-attach-to-previous-cell"
    (with-screen (s 10 5)
      (utf8-feed s (coerce (list #\a (code-char #x0080)) 'string))
      (let ((cell (screen-cell s 0 0)))
        (expect (char= #\a (cell-char cell)))
        (expect (null (nerimux/terminal/types:cell-combining cell))))
      ;; It went to a cell of its own, so the cursor advanced past the base.
      (expect (= 2 (screen-cursor-x s)))))

  ;; A C0 byte fed to the parser drives its own action (TAB moves to the next
  ;; tab stop) instead of being absorbed by the preceding cell.
  (it "c0-tab-byte-drives-its-own-action-not-a-combine"
    (with-screen (s 20 5)
      (feed s (format nil "a~C" #\Tab))
      (check-cursor s 8 0)
      (expect (null (nerimux/terminal/types:cell-combining (screen-cell s 0 0)))))))

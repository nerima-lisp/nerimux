(in-package #:nerimux/test/terminal)

(declaim (notinline nerimux/terminal/csi::%csi-leading-int
                    nerimux/terminal/csi::%csi-decstbm-params))

(describe "terminal-suite/ech"

  (it "ech-erases-n-chars-in-place"
    (with-screen (s 20 5)
      (feed s "ABCDE")              ; cells 0-4 = A B C D E, cursor at 5
      (feed s (esc "[1;4H"))        ; move cursor to col 3 (1-based)
      (check-cursor s 3 0)
      (feed s (esc "[3X"))          ; ECH 3 — erase cols 3,4,5
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))
      (expect (char= #\C (char-at s 2 0)))
      (expect (char= #\Space (char-at s 3 0)))
      (expect (char= #\Space (char-at s 4 0)))
      (expect (char= #\Space (char-at s 5 0)))
      (check-cursor s 3 0)))

  (it "ech-default-one-char"
    (with-screen (s 10 5)
      (feed s "ABCD")
      (feed s (esc "[1;3H"))   ; cursor at col 2
      (feed s (esc "[X"))      ; ECH 1 (default)
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\D (char-at s 3 0)))
      (check-cursor s 2 0))))

(describe "terminal-suite/dsr"

  (it "dsr-5n-replies-ok-without-altering-screen"
    (with-screen (s 20 5)
      (feed s "A")
      (feed s (esc "[5n"))   ; DSR — report status (queues ESC[0n)
      (feed s "B")
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))
      (check-cursor s 2 0)
      (expect (some (lambda (r) (search "[0n" r))
                    (nerimux/terminal/types:screen-response-queue s))))))

(describe "terminal-suite/ich-dch"

  (it "ich-inserts-blanks-and-shifts-right"
    (with-screen (s 10 5)
      (feed s "ABCDE")              ; row 0: A B C D E, cursor at 5
      (feed s (esc "[1;2H"))        ; cursor → col 1 (1-based 2)
      (check-cursor s 1 0)
      (feed s (esc "[2@"))          ; ICH 2 — insert 2 blanks at col 1
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\Space (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\B (char-at s 3 0)))
      (expect (char= #\C (char-at s 4 0)))
      (check-cursor s 1 0)))

  (it "ich-default-one-char"
    (with-screen (s 10 5)
      (feed s "XY")
      (feed s (esc "[1;1H"))   ; cursor at col 0
      (feed s (esc "[@"))      ; ICH 1 (default)
      (expect (char= #\Space (char-at s 0 0)))
      (expect (char= #\X (char-at s 1 0)))
      (expect (char= #\Y (char-at s 2 0)))
      (check-cursor s 0 0)))

  (it "dch-deletes-and-shifts-left"
    (with-screen (s 10 5)
      (feed s "ABCDE")              ; row 0: A B C D E, cursor at 5
      (feed s (esc "[1;2H"))        ; cursor → col 1
      (feed s (esc "[2P"))          ; DCH 2 — delete 2 chars at col 1
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\D (char-at s 1 0)))
      (expect (char= #\E (char-at s 2 0)))
      (expect (char= #\Space (char-at s 3 0)))
      (expect (char= #\Space (char-at s 4 0)))
      (check-cursor s 1 0)))

  (it "dch-default-one-char"
    (with-screen (s 10 5)
      (feed s "ABCD")
      (feed s (esc "[1;2H"))   ; cursor at col 1
      (feed s (esc "[P"))      ; DCH 1 (default)
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\C (char-at s 1 0)))
      (expect (char= #\D (char-at s 2 0)))
      (expect (char= #\Space (char-at s 3 0)))
      (check-cursor s 1 0))))

(describe "terminal-suite/il-dl"

  (it "il-inserts-blank-line-at-cursor"
    (with-screen (s 10 5)
      (feed-lines s "row0" "row1" "row2")
      (feed s (esc "[2;1H"))    ; cursor at row 1 (1-based 2)
      (feed s (esc "[L"))       ; IL 1 (default) — insert blank line
      (check-row s 0 "row0")
      (expect (row-blank-p s 1))
      (check-row s 2 "row1")))

  (it "il-two-lines"
    (with-screen (s 10 5)
      (feed-lines s "row0" "row1" "row2" "row3")
      (feed s (esc "[2;1H"))   ; cursor at row 1
      (feed s (esc "[2L"))     ; IL 2
      (check-row s 0 "row0")
      (expect (row-blank-p s 1))
      (expect (row-blank-p s 2))
      (check-row s 3 "row1")))

  (it "dl-deletes-current-line"
    (with-screen (s 10 5)
      (feed-lines s "row0" "row1" "row2")
      (feed s (esc "[2;1H"))    ; cursor at row 1
      (feed s (esc "[M"))       ; DL 1 (default)
      (check-row s 0 "row0")
      (check-row s 1 "row2")    ; row 2 moved up
      (expect (row-blank-p s 2))))

  (it "dl-two-lines"
    (with-screen (s 10 5)
      (feed-lines s "row0" "row1" "row2" "row3")
      (feed s (esc "[2;1H"))   ; cursor at row 1
      (feed s (esc "[2M"))     ; DL 2
      (check-row s 0 "row0")
      (check-row s 1 "row3")
      (expect (row-blank-p s 2)))))

(describe "terminal-suite/decstbm-csi"

  (it "decstbm-csi-sets-scroll-region"
    (with-screen (s 10 10)
      (feed s (esc "[3;8H"))    ; move cursor away from home
      (feed s (esc "[3;8r"))    ; DECSTBM: top=3 (1-based) → 2, bottom=8 → 7
      (expect (= 2 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 7 (nerimux/terminal/types:screen-scroll-bottom s)))
      (check-cursor s 0 0)))

  (it "decstbm-csi-no-params-resets-to-full-screen"
    (with-screen (s 10 10)
      (feed s (esc "[3;8r"))
      (feed s (esc "[r"))
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 9 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "decstbm-csi-scroll-region-constrains-scroll"
    (with-screen (s 10 5)
      (feed-lines s "row0" "row1" "row2" "row3")
      (feed s (esc "[2;3r"))
      (feed s (esc "[2;1H"))    ; cursor at row 1
      (feed s (esc "[S"))       ; SU 1
      (check-row s 0 "row0")
      (check-row s 1 "row2")))

  (it "decstbm-csi-invalid-top-greater-than-bottom-resets-to-full-screen"
    (with-screen (s 10 10)
      (feed s (esc "[3;8r"))
      (expect (= 2 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 7 (nerimux/terminal/types:screen-scroll-bottom s)))
      (feed s (esc "[8;3r"))
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 9 (nerimux/terminal/types:screen-scroll-bottom s))))))

(describe "terminal-suite/execute-csi-direct"

  (it "execute-csi-cup-direct"
    (with-screen (s 20 10)
      (nerimux/terminal/csi:execute-csi s #\H nil nil '(3 5))
      (check-cursor s 4 2)))

  (it "execute-csi-sgr-direct"
    (with-screen (s 20 10)
      (nerimux/terminal/csi:execute-csi s #\m nil nil '(31))
      (expect (= 1 (nerimux/terminal/types:screen-cur-fg s)))))

  (it "execute-csi-unknown-final-is-noop"
    (with-screen (s 20 10)
      (finishes (nerimux/terminal/csi:execute-csi s #\z nil nil '()))
      (check-cursor s 0 0)
      (check-sgr-state s :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)))

  (it "execute-csi-unknown-intermed-is-noop"
    (with-screen (s 20 10)
      (finishes (nerimux/terminal/csi:execute-csi s #\H #\! nil '(3 5)))
      (check-cursor s 0 0))))

(describe "terminal-suite/csi-decstbm-params"

  (it "%csi-decstbm-params-table"
    (dolist (row '((10 10 3 8  2   7   "normal: p1=3,p2=8 → top=2,bottom=7")
                   (10 10 0 5  0   nil "p1=0 → top=0 (skip bottom)")
                   (10  8 1 0  nil 7   "p2=0 → bottom=height-1=7 (skip top)")))
      (destructuring-bind (sw sh p1 p2 expected-top expected-bottom desc) row
        (declare (ignore desc))
        (with-screen (s sw sh)
          (multiple-value-bind (top bottom)
              (nerimux/terminal/csi::%csi-decstbm-params s p1 p2)
            (when expected-top
              (expect (= expected-top top)))
            (when expected-bottom
              (expect (= expected-bottom bottom)))))))))

(describe "terminal-suite/csi-rules-macro-and-helpers"

  (it "define-csi-rules-macro-is-defined"
    (expect (macro-function 'nerimux/terminal/csi::define-csi-rules)))

  (it "execute-csi-has-docstring"
    (let ((doc (documentation 'nerimux/terminal/csi:execute-csi 'function)))
      (expect (and (stringp doc) (plusp (length doc))))))

  (it "csi-leading-int-table"
    (dolist (row (list (list 42       42 "plain integer passes through")
                       (list '(4 3)   4  "colon-group list → its head")
                       (list nil      0  "absent parameter → 0")
                       (list '(nil 3) 0  "colon-group with NIL head → 0")))
      (destructuring-bind (param expected desc) row
        (declare (ignore desc))
        (expect (= expected (nerimux/terminal/csi::%csi-leading-int param)))))))

(describe "terminal-suite/csi-decstr-ansi-mode-dispatch"

  (it "decstr-via-csi-resets-insert-mode-without-clearing-screen"
    (with-screen (s 10 5)
      (feed s "ABCDE")
      (feed s (esc "[4h"))          ; enable IRM first
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-truthy)
      (feed s (esc "[!p"))          ; DECSTR — soft reset
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-falsy)
      (expect (string= "ABCDE" (row-string s 0 :end 5)))))

  (it "ansi-mode-h-l-via-csi-toggles-insert-mode"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-falsy)
      (feed s (esc "[4h"))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-truthy)
      (feed s (esc "[4l"))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-falsy))))

(in-package #:nerimux/test/terminal)

(describe "special"

  (it "csi-private-lt-marker-consumed-not-stray"
    (with-screen (s 10 2)
      (feed s "a")
      (feed s (esc "[<t"))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "esc-hash-8-decaln-fills-screen-with-e"
    (with-screen (s 4 2)
      (feed s (esc "#8"))
      (dotimes (y 2)
        (dotimes (x 4)
          (expect (char= #\E (char-at s x y)))))))

  (it "esc-hash-selector-consumed-not-stray"
    (with-screen (s 10 2)
      (feed s "a")
      (feed s (esc "#5"))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "esc-star-plus-g2-g3-designator-consumed-not-stray"
    (with-screen (s 10 2)
      (feed s "a")
      (feed s (esc "*0"))
      (feed s (esc "+B"))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "esc-space-and-percent-two-byte-seqs-consumed-not-stray"
    (with-screen (s 10 2)
      (feed s "a")
      (feed s (esc " F"))
      (feed s (esc "%G"))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "csi-unknown"
    (with-screen (s 10 2)
      (feed s "a")
      (feed s (esc "[z"))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "dec-pm-hide-show-cursor"
    (with-screen (s 10 2)
      (feed s "a")
      (feed s (esc "[?25l"))
      (feed s "b")
      (feed s (esc "[?25h"))
      (feed s "c")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))
      (expect (char= #\c (char-at s 2 0))))))

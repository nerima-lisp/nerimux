(in-package #:nerimux/test/terminal)

(describe "terminal-suite/direct-line-edit"

  (it "insert-lines-at-row-zero-pushes-content-down"
    (with-screen (s 5 4)
      (feed-lines s "AA" "BB" "CC")
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:insert-lines s 1)
      (expect (row-blank-p s 0))
      (check-row s 1 "AA")))

  (it "delete-lines-at-row-zero-pulls-content-up"
    (with-screen (s 5 4)
      (feed-lines s "AA" "BB" "CC" "DD")
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:delete-lines s 1)
      (check-row s 0 "BB")
      (expect (row-blank-p s 3))))

  (it "insert-lines-ignored-when-cursor-above-scroll-region"
    (with-screen (s 5 5)
      (feed-lines s "AA" "BB" "CC" "DD" "EE")
      (feed s (esc "[3;5r"))      ; DECSTBM region rows 3-5 (0-based 2-4); homes cursor (0,0)
      (check-cursor s 0 0)        ; cursor is above scroll-top (row 2)
      (nerimux/terminal/actions:insert-lines s 1)
      (check-row s 0 "AA")        ; rows above the region must be untouched
      (check-row s 1 "BB")
      (check-row s 2 "CC")))

  (it "delete-lines-ignored-when-cursor-above-scroll-region"
    (with-screen (s 5 5)
      (feed-lines s "AA" "BB" "CC" "DD" "EE")
      (feed s (esc "[3;5r"))      ; region rows 2-4 (0-based); cursor homed to (0,0)
      (nerimux/terminal/actions:delete-lines s 1)
      (check-row s 0 "AA")
      (check-row s 1 "BB")))

  (it "delete-lines-n-larger-than-region-blanks-all-region-rows"
    (with-screen (s 5 4)
      (feed-lines s "AA" "BB" "CC" "DD")
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:delete-lines s 99)
      (dotimes (y 4)
        (expect (row-blank-p s y)))))

  (it "insert-lines-n-larger-than-region-blanks-all-region-rows"
    (with-screen (s 5 4)
      (feed-lines s "AA" "BB" "CC" "DD")
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:insert-lines s 99)
      (dotimes (y 4)
        (expect (row-blank-p s y))))))

(describe "terminal-suite/scroll-screen-to-history-suite"

  (it "scroll-screen-to-history-pushes-all-rows"
    (with-screen (s 5 3)
      (feed-lines s "AA" "BB" "CC")
      (nerimux/terminal/actions:scroll-screen-to-history s)
      (expect (= 3 (length (nerimux/terminal/types:screen-scrollback s))))))

  (it "scroll-screen-to-history-top-row-is-oldest"
    (with-screen (s 5 3)
      (feed-lines s "ROW0" "ROW1" "ROW2")
      (nerimux/terminal/actions:scroll-screen-to-history s)
      (let ((scrollback (nerimux/terminal/types:screen-scrollback s)))
        (let ((newest-row (first scrollback))
              (oldest-row (first (last scrollback))))
          (expect (char= #\R (cell-char (aref newest-row 0))))
          (expect (char= #\0 (cell-char (aref oldest-row 3))))
          (expect (char= #\2 (cell-char (aref newest-row 3))))))))

  (it "scroll-screen-to-history-is-noop-on-alt-screen"
    (with-screen (s 5 3)
      (feed-lines s "AA" "BB" "CC")
      (nerimux/terminal/actions:enter-alt-screen s)
      (nerimux/terminal/actions:scroll-screen-to-history s)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  (it "scroll-screen-to-history-respects-history-cap"
    (with-screen (s 5 10)
      (let ((cap nerimux/terminal:+max-scrollback-lines+))
        (setf (nerimux/terminal/types:screen-scrollback s)
              (loop repeat (- cap 3)
                    collect (make-array 5 :initial-element
                                          (nerimux/terminal/types:blank-cell))))
        (dotimes (_ 10) (feed s "AAAAA"))
        (nerimux/terminal/actions:scroll-screen-to-history s)
        (expect (<= (length (nerimux/terminal/types:screen-scrollback s)) cap))))))

(describe "terminal-suite/dec-rect-ops-suite"


  (it "decera-erases-rectangle"
    (with-screen (s 10 5)
      (feed s "AAAAAAAAAA")     ; row 0 = "AAAAAAAAAA"
      (feed s "BBBBBBBBBB")     ; row 1
      (nerimux/terminal/actions:decera s 1 2 2 4)
      (expect (char= #\Space (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\Space (char-at s 3 0)))
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\A (char-at s 4 0)))))

  (it "decera-degenerate-rectangle-is-noop"
    (with-screen (s 5 5)
      (feed s "AAAAA")
      (nerimux/terminal/actions:decera s 3 1 1 5)
      (expect (char= #\A (char-at s 0 0)))))

  (it "decera-clamps-out-of-bounds-rectangle"
    (with-screen (s 5 3)
      (feed s "AAAAA")
      (nerimux/terminal/actions:decera s 1 1 99 99)
      (dotimes (y 3)
        (expect (row-blank-p s y)))))


  (it "decfra-fills-rectangle-with-char"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:decfra s 88 1 2 2 4)
      (expect (char= #\X (char-at s 1 0)))
      (expect (char= #\X (char-at s 2 0)))
      (expect (char= #\X (char-at s 3 0)))
      (expect (char= #\X (char-at s 1 1)))
      (expect (char= #\Space (char-at s 0 0)))
      (expect (char= #\Space (char-at s 4 0)))))

  (it "decfra-zero-char-code-fills-with-space"
    (with-screen (s 5 3)
      (feed s "AAAAA")
      (nerimux/terminal/actions:decfra s 0 1 1 1 5)
      (dotimes (x 5)
        (expect (char= #\Space (char-at s x 0))))))

  (it "decfra-degenerate-rectangle-is-noop"
    (with-screen (s 5 3)
      (feed s "AAAAA")
      (nerimux/terminal/actions:decfra s 88 1 5 1 1)
      (expect (char= #\A (char-at s 0 0)))))


  (it "deccra-action-direct-copies-rectangle-to-target"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:decfra s 65 1 1 2 3)  ; 'A'=65
      (nerimux/terminal/actions:deccra s 1 1 2 3 4 6)
      (expect (char= #\A (char-at s 5 3)))
      (expect (char= #\A (char-at s 6 3)))
      (expect (char= #\A (char-at s 7 3)))
      (expect (char= #\A (char-at s 0 0)))))

  (it "deccra-overlapping-regions-are-handled-correctly"
    (with-screen (s 10 3)
      (nerimux/terminal/actions:write-char-at-cursor s #\A)
      (nerimux/terminal/actions:write-char-at-cursor s #\B)
      (nerimux/terminal/actions:write-char-at-cursor s #\C)
      (nerimux/terminal/actions:deccra s 1 1 1 3 1 2)
      (expect (char= #\A (char-at s 1 0)))
      (expect (char= #\B (char-at s 2 0)))
      (expect (char= #\C (char-at s 3 0)))))

  (it "deccra-degenerate-source-is-noop"
    (with-screen (s 5 3)
      (nerimux/terminal/actions:decfra s 65 1 1 3 5)   ; fill whole screen with 'A'
      (nerimux/terminal/actions:deccra s 3 1 1 5 1 1)
      (expect (char= #\A (char-at s 0 0)))))

  (it "deccra-target-clamped-to-screen-bounds"
    (with-screen (s 5 3)
      (nerimux/terminal/actions:decfra s 90 1 1 2 2)   ; 'Z'=90
      (nerimux/terminal/actions:deccra s 1 1 2 2 3 4)
      (expect (char= #\Z (char-at s 3 2))))))

(in-package #:nerimux/test/terminal)

(describe "terminal-suite/basic-text"

  (it "plain-text"
    (with-screen (s 20 5)
      (feed s "hello")
      (expect (string= "hello" (row-string s 0 :end 5)))
      (check-cursor s 5 0)))

  (it "crlf"
    (with-screen (s 20 5)
      (feed s "ab")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "cd")
      (expect (string= "ab" (row-string s 0 :end 2)))
      (expect (string= "cd" (row-string s 1 :end 2)))
      (check-cursor s 2 1)))

  (it "carriage-return"
    (with-screen (s 20 5)
      (feed s "abc")                         ; cursor at (3, 0)
      (check-cursor s 3 0)
      (feed s (string #\Return))             ; CR → column 0, row unchanged
      (check-cursor s 0 0)
      (expect (string= "abc" (row-string s 0 :end 3)))
      (feed s "XY")
      (expect (string= "XYc" (row-string s 0 :end 3)))
      (check-cursor s 2 0)))

  (it "carriage-return-keeps-row"
    (with-screen (s 20 5)
      (feed s (esc "[3;6H"))                 ; cursor → (5, 2)
      (check-cursor s 5 2)
      (feed s (string #\Return))             ; CR → column 0, still row 2
      (check-cursor s 0 2)))

  (it "line-wrap"
    (with-screen (s 4 3)
      (feed s "abcde")
      (expect (string= "abcd" (row-string s 0)))
      (expect (char= #\e (char-at s 0 1)))
      (check-cursor s 1 1)))

  (it "backspace"
    (with-screen (s 10 2)
      (feed s "abc")
      (feed s (string #\Backspace))
      (check-cursor s 2 0)))

  (it "tab-stop"
    (with-screen (s 40 2)
      (feed s "a")
      (feed s (string #\Tab))
      (check-cursor s 8 0)))

  (it "tab-already-at-stop"
    (with-screen (s 40 2)
      (feed s "        ")   ; 8 spaces → cursor at (8, 0)
      (feed s "a")          ; cursor at (9, 0)
      (feed s (esc "[1;9H")) ; CUP row=1 col=9 (1-based) → (8, 0)
      (feed s (string #\Tab))
      (check-cursor s 16 0))))

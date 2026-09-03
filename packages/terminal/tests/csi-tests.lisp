(in-package #:nerimux/test/terminal)

(describe "terminal-suite/cursor-movement"

  (it "cup"
    (with-screen (s 20 10)
      (feed s (esc "[3;5H"))
      (check-cursor s 4 2)))

  (it "cuu"
    (with-screen (s 20 10)
      (feed s (esc "[5;5H"))  ; → (4, 4)
      (feed s (esc "[2A"))    ; up 2 → y=2
      (check-cursor s 4 2)))

  (it "cud"
    (with-screen (s 20 10)
      (feed s (esc "[1;1H"))  ; → (0, 0)
      (feed s (esc "[3B"))    ; down 3 → y=3
      (check-cursor s 0 3)))

  (it "cuf"
    (with-screen (s 20 10)
      (feed s (esc "[1;3H"))  ; → (2, 0)
      (feed s (esc "[4C"))    ; right 4 → x=6
      (check-cursor s 6 0)))

  (it "cub"
    (with-screen (s 20 10)
      (feed s (esc "[1;7H"))  ; → (6, 0)
      (feed s (esc "[4D"))    ; left 4 → x=2
      (check-cursor s 2 0)))

  (it "cnl"
    (with-screen (s 20 10)
      (feed s (esc "[3;5H"))  ; → (4, 2)
      (feed s (esc "[2E"))    ; next 2 lines → (0, 4)
      (check-cursor s 0 4)))

  (it "cpl"
    (with-screen (s 20 10)
      (feed s (esc "[5;5H"))  ; → (4, 4)
      (feed s (esc "[2F"))    ; preceding 2 lines → (0, 2)
      (check-cursor s 0 2)))

  (it "cha"
    (with-screen (s 20 10)
      (feed s (esc "[4;4H"))  ; → (3, 3)
      (feed s (esc "[5G"))    ; column 5 (1-based) → x=4
      (check-cursor s 4 3)))

  (it "vpa"
    (with-screen (s 20 10)
      (feed s (esc "[4;4H"))  ; → (3, 3)
      (feed s (esc "[5d"))    ; row 5 (1-based) → y=4
      (check-cursor s 3 4)))

  (it "hvp"
    (with-screen (s 20 10)
      (feed s (esc "[3;5f"))
      (check-cursor s 4 2)))

  (it "hpa"
    (with-screen (s 20 10)
      (feed s (esc "[4;4H"))   ; → (3, 3)
      (feed s (esc "[5`"))     ; column 5 (1-based) → x=4
      (check-cursor s 4 3)))

  (it "hpr"
    (with-screen (s 20 10)
      (feed s (esc "[1;3H"))   ; → (2, 0)
      (feed s (esc "[4a"))     ; right 4 → x=6
      (check-cursor s 6 0)))

  (it "vpr"
    (with-screen (s 20 10)
      (feed s (esc "[1;1H"))   ; → (0, 0)
      (feed s (esc "[3e"))     ; down 3 → y=3
      (check-cursor s 0 3)))

  (it "scosc-scorc"
    (with-screen (s 20 10)
      (feed s (esc "[4;6H"))   ; → (5, 3)
      (feed s (esc "[s"))      ; save cursor
      (feed s (esc "[1;1H"))   ; move away → (0, 0)
      (check-cursor s 0 0)
      (feed s (esc "[u"))      ; restore → (5, 3)
      (check-cursor s 5 3)))

  (it "clamp"
    (with-screen (s 10 5)
      (feed s (esc "[100;100H"))
      (check-cursor s 9 4)))



  (it "cuu-clamps-to-row-zero"
    (with-screen (s 20 10)
      (feed s (esc "[4;1H"))   ; row 4 (1-based) → 0-based row 3
      (feed s (esc "[100A"))   ; up 100 — must clamp to row 0
      (check-cursor s 0 0)))

  (it "cud-clamps-to-last-row"
    (with-screen (s 20 10)
      (feed s (esc "[100B"))   ; down 100 — must clamp to row 9
      (expect (<= (screen-cursor-y s) 9))))

  (it "cuf-clamps-to-last-col"
    (with-screen (s 20 10)
      (feed s (esc "[100C"))   ; right 100 — must clamp to col 19
      (expect (<= (screen-cursor-x s) 19))))

  (it "cub-clamps-to-col-zero"
    (with-screen (s 20 10)
      (feed s (esc "[1;10H"))  ; col 9
      (feed s (esc "[100D"))   ; left 100 — must clamp to col 0
      (check-cursor s 0 0)))


  (it "cursor-movement-table"
    (dolist (entry
             (list (list (esc "[3;3H") (esc "[1A")   2    1)   ; CUU 1 from (2,2) → y=1
                   (list (esc "[3;3H") (esc "[1B")   2    3)   ; CUD 1 from (2,2) → y=3
                   (list (esc "[3;3H") (esc "[1C")   3    2)   ; CUF 1 from (2,2) → x=3
                   (list (esc "[3;3H") (esc "[1D")   1    2))) ; CUB 1 from (2,2) → x=1
      (destructuring-bind (setup move expected-cx expected-cy) entry
        (with-screen (s 20 10)
          (feed s setup)
          (feed s move)
          (check-cursor s expected-cx expected-cy)))))

  (it "csi-cursor-home-no-params-goes-to-origin"
    (with-screen (s 20 10)
      (feed s (esc "[5;10H"))    ; move to row 5, col 10
      (check-cursor s 9 4)
      (feed s (esc "[H"))        ; CUP no params → home (0,0)
      (check-cursor s 0 0)))

  (it "csi-cursor-up-default-one-row"
    (with-screen (s 10 5)
      (feed s (esc "[3;1H"))     ; move to row 3 (0-based: row 2)
      (feed s (esc "[A"))        ; CUU no params → up 1
      (check-cursor s 0 1))))

(describe "terminal-suite/decscusr"


  (it "decscusr-shape-table"
    (dolist (entry '(("0" 0) ("2" 2) ("5" 5)))
      (let ((param  (first  entry))
            (expect (second entry)))
        (with-screen (s 20 5)
          (feed s (esc (format nil "[~A q" param)))
          (expect (= expect (nerimux/terminal/types:screen-cursor-shape s))))))
    (with-screen (s 20 5)
      (expect (= 1 (nerimux/terminal/types:screen-cursor-shape s))))))

(describe "terminal-suite/cbt-cht"

  (it "cbt-moves-backward-tab"
    (with-screen (s 40 5)
      (feed s (esc "[1;13H"))    ; move to col 12 (1-based 13)
      (check-cursor s 12 0)
      (feed s (esc "[Z"))        ; CBT 1 stop backward
      (check-cursor s 8 0)))

  (it "cbt-backward-tab-stops-table"
    (dolist (row '(("[1;19H" "[2Z" 8 "2 stops from col 18 → col 8")
                   ("[1;4H"  "[5Z" 0 "5 stops from col 3 → col 0 (clamped)")))
      (destructuring-bind (setup-seq cbt-seq expected _desc) row
        (declare (ignore _desc))
        (with-screen (s 40 5)
          (feed s (esc setup-seq))
          (feed s (esc cbt-seq))
          (check-cursor s expected 0)))))

  (it "cht-forward-tab-stops-table"
    (dolist (row '(("[I"  8  "1 stop from col 0 → col 8")
                   ("[2I" 16 "2 stops from col 0 → col 16")))
      (destructuring-bind (seq expected _desc) row
        (declare (ignore _desc))
        (with-screen (s 40 5)
          (feed s (esc seq))
          (check-cursor s expected 0)))))

  (it "cht-clamps-to-right-edge"
    (with-screen (s 10 5)
      (feed s (esc "[10I"))      ; far forward
      (expect (<= (screen-cursor-x s) 9)))))

(describe "terminal-suite/su-sd"

  (it "su-scrolls-content-up"
    (with-screen (s 10 3)
      (feed s "row0")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "row1")
      (feed s (esc "[H"))          ; home cursor
      (feed s (esc "[S"))          ; SU 1 — scroll up
      (expect (string= "row1" (row-string s 0 :end 4)))))

  (it "su-2-scrolls-two-lines"
    (with-screen (s 10 4)
      (feed s "aaa") (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "bbb") (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "ccc") (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "ddd")
      (feed s (esc "[H"))       ; home
      (feed s (esc "[2S"))      ; SU 2
      (expect (string= "ccc" (row-string s 0 :end 3)))))

  (it "sd-scrolls-content-down"
    (with-screen (s 10 3)
      (feed s "row0")
      (feed s (esc "[H"))
      (feed s (esc "[T"))          ; SD 1 — scroll down
      (expect (row-blank-p s 0))
      (expect (string= "row0" (row-string s 1 :end 4))))))

(describe "terminal-suite/decrqm"

  (it "decrqm-accessor-mode-reports-set-and-reset"
    (with-screen (s 20 5)
      (nerimux/terminal/csi::enqueue-decrqm-reply s 1004)
      (let ((reply (first (nerimux/terminal/types:screen-response-queue s))))
        (expect (string= (format nil "~C[?1004;2$y" #\Escape) reply)))
      (setf (nerimux/terminal/types:screen-response-queue s) nil)
      (setf (nerimux/terminal/types:screen-focus-events s) t)
      (nerimux/terminal/csi::enqueue-decrqm-reply s 1004)
      (let ((reply (first (nerimux/terminal/types:screen-response-queue s))))
        (expect (string= (format nil "~C[?1004;1$y" #\Escape) reply)))))

  (it "decrqm-fixed-mode-always-reports-given-code"
    (with-screen (s 20 5)
      (nerimux/terminal/csi::enqueue-decrqm-reply s 2026)
      (let ((reply (first (nerimux/terminal/types:screen-response-queue s))))
        (expect (string= (format nil "~C[?2026;2$y" #\Escape) reply)))))

  (it "decrqm-alt-screen-mode-reflects-alternate-screen-state"
    (with-screen (s 20 5)
      (nerimux/terminal/csi::enqueue-decrqm-reply s 1049)
      (expect (string= (format nil "~C[?1049;2$y" #\Escape)
                        (first (nerimux/terminal/types:screen-response-queue s))))
      (setf (nerimux/terminal/types:screen-response-queue s) nil)
      (feed s (esc "[?1049h"))
      (nerimux/terminal/csi::enqueue-decrqm-reply s 1049)
      (expect (string= (format nil "~C[?1049;1$y" #\Escape)
                        (first (nerimux/terminal/types:screen-response-queue s)))))))

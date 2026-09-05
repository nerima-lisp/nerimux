(in-package #:nerimux/test/terminal)

(describe "terminal-suite/charset-invoke-suite"

  (it "screen-invoked-charset-returns-g0-charset"
    (with-screen (s 10 5)
      (expect (eq :ascii (nerimux/terminal/actions:screen-invoked-charset s :g0)))))

  (it "screen-invoked-charset-returns-g1-charset"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g1 :dec-graphics)
      (expect (eq :dec-graphics (nerimux/terminal/actions:screen-invoked-charset s :g1)))))

  (it "designate-charset-g0-and-invoke-activates-charset"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  (it "designate-charset-g1-does-not-activate-immediately"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g1 :dec-graphics)
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "invoke-charset-so-activates-g1"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g1 :dec-graphics)
      (nerimux/terminal/actions:invoke-charset s :g1)
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  (it "invoke-charset-si-restores-g0"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g1 :dec-graphics)
      (nerimux/terminal/actions:invoke-charset s :g1)
      (nerimux/terminal/actions:invoke-charset s :g0)
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "g1-charset-via-parser-esc-paren-zero"
    (with-screen (s 10 5)
      (feed s (esc ")0"))                    ; ESC ) 0 = designate G1 to DEC graphics
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "g1-charset-so-si-via-parser"
    (with-screen (s 10 5)
      (feed s (esc ")0"))                         ; designate G1 to DEC graphics
      (feed s (string (code-char #x0E)))          ; SO = invoke G1
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))
      (feed s (string (code-char #x0F)))          ; SI = invoke G0
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s))))))

(describe "terminal-suite/set-screen-cwd-suite"

  (it "set-screen-cwd-stores-path"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-cwd s "/home/user/projects")
      (expect (string= "/home/user/projects" (nerimux/terminal/types:screen-cwd s)))))

  (it "set-screen-cwd-accepts-empty-string"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-cwd s "/initial/path")
      (nerimux/terminal/actions:set-screen-cwd s "")
      (expect (string= "" (nerimux/terminal/types:screen-cwd s))))))

(describe "terminal-suite/erase-display-mode3-suite"

  (it "erase-display-mode-3-clears-visible-grid"
    (with-screen (s 5 3)
      (dotimes (y 3)
        (dotimes (x 5)
          (nerimux/terminal/actions:write-char-at-cursor s #\X)
          (nerimux/terminal/actions:set-cursor s (1+ (min x 3)) y)))
      (nerimux/terminal/actions:erase-display s 3)
      (dotimes (y 3)
        (expect (row-blank-p s y)))))

  (it "erase-display-mode-3-clears-both-grid-and-scrollback"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2" "L3")
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))
      (nerimux/terminal/actions:set-cursor s 0 0)
      (feed s "AAAAA")
      (nerimux/terminal/actions:erase-display s 3)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))
      (expect (row-blank-p s 0))))


  (it "irm-insert-mode-shifts-line-right"
    (with-screen (s 10 5)
      (feed s "abc")
      (feed s (esc "[H"))      ; cursor home (col 0)
      (feed s (esc "[4h"))     ; IRM on
      (feed s "XY")
      (expect (string= "XYabc" (row-string s 0 :end 5)))))

  (it "irm-replace-mode-overwrites"
    (with-screen (s 10 5)
      (feed s "abc")
      (feed s (esc "[H"))
      (feed s (esc "[4l"))     ; IRM off (explicit)
      (feed s "XY")
      (expect (string= "XYc" (row-string s 0 :end 3)))))

  (it "irm-set-and-reset-toggle-screen-flag"
    (with-screen (s 10 5)
      (feed s (esc "[4h"))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-truthy)
      (feed s (esc "[4l"))
      (expect (not (nerimux/terminal/types:screen-insert-mode s)))))

  (it "ris-resets-mode-flags-table"
    (dolist (row (list (list (esc "[4h")  #'nerimux/terminal/types:screen-insert-mode   "insert mode")
                       (list (esc "[20h") #'nerimux/terminal/types:screen-newline-mode   "newline mode")
                       (list (esc "[?5h") #'nerimux/terminal/types:screen-reverse-screen "reverse-screen")))
      (destructuring-bind (enable-seq accessor desc) row
        (declare (ignore desc))
        (with-screen (s 10 5)
          (feed s enable-seq)
          (feed s (esc "c"))
          (expect (funcall accessor s) :to-be-falsy)))))


  (it "lnm-newline-mode-lf-also-carriage-returns"
    (with-screen (s 10 5)
      (feed s (esc "[20h"))             ; LNM on
      (feed s "a")
      (feed s (string #\Linefeed))      ; LF
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 0 1)))))

  (it "lnm-off-lf-keeps-column"
    (with-screen (s 10 5)
      (feed s "a")
      (feed s (string #\Linefeed))      ; LF
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 1)))))

  (it "lnm-set-and-reset-toggle-screen-flag"
    (with-screen (s 10 5)
      (feed s (esc "[20h"))
      (expect (nerimux/terminal/types:screen-newline-mode s) :to-be-truthy)
      (feed s (esc "[20l"))
      (expect (not (nerimux/terminal/types:screen-newline-mode s)))))


  (it "decscnm-set-and-reset-toggle-screen-flag"
    (with-screen (s 10 5)
      (feed s (esc "[?5h"))
      (expect (nerimux/terminal/types:screen-reverse-screen s) :to-be-truthy)
      (feed s (esc "[?5l"))
      (expect (not (nerimux/terminal/types:screen-reverse-screen s)))))


  (it "decstr-resets-modes-but-preserves-screen-and-cursor"
    (with-screen (s 10 5)
      (feed s "hello")                 ; content on row 0
      (feed s (esc "[4h"))             ; IRM on
      (feed s (esc "[?7l"))            ; autowrap off
      (feed s (esc "[?25l"))           ; cursor hidden
      (feed s (esc "[2;4r"))           ; scroll region rows 2..4 (DECSTBM homes cursor)
      (feed s (esc "[1;6H"))           ; reposition cursor to row 1, col 6 (0-idx col 5)
      (feed s (esc "[!p"))             ; DECSTR soft reset
      (expect (not (nerimux/terminal/types:screen-insert-mode s)))
      (expect (nerimux/terminal/types:screen-autowrap s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-cursor-visible s) :to-be-truthy)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 4 (nerimux/terminal/types:screen-scroll-bottom s)))
      (expect (string= "hello" (row-string s 0 :end 5)))
      (expect (= 5 (nerimux/terminal/types:screen-cursor-x s)))))

  (it "decstr-resets-sgr-pen"
    (with-screen (s 10 5)
      (feed s (esc "[1;31m"))          ; bold red
      (feed s (esc "[!p"))             ; DECSTR
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs s))))))

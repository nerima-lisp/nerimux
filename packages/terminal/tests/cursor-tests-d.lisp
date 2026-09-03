(in-package #:nerimux/test/terminal)

(describe "terminal-suite/direct-action-cursor"

  (it "cursor-lf-moves-down-within-screen"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:cursor-lf s)   ; row 0 → row 1
      (check-cursor s 0 1)
      (nerimux/terminal/actions:cursor-lf s)   ; row 1 → row 2
      (check-cursor s 0 2)))

  (it "cursor-lf-cancels-pending-wrap"
    (with-screen (s 3 3)
      (feed s "abc")                     ; fills row 0; pending-wrap set
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-truthy)
      (nerimux/terminal/actions:cursor-lf s)
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-falsy)))

  (it "cursor-lf-at-scroll-bottom-does-not-exceed-screen"
    (with-screen (s 5 3)
      (nerimux/terminal/actions:set-cursor s 0 2)   ; bottom row
      (nerimux/terminal/actions:cursor-lf s)
      (expect (<= (screen-cursor-y s) 2)))))

(describe "terminal-suite/cursor-nl-mode-suite"

  (it "cursor-nl-default-lnm-off-preserves-column"
    (with-screen (s 10 5)
      (feed s "hello")                         ; cursor at col 5, row 0
      (nerimux/terminal/actions:cursor-nl s)   ; default LNM off
      (check-cursor s 5 1)))

  (it "cursor-nl-with-lnm-on-resets-column-to-zero"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-newline-mode s) t)
      (feed s "hello")                         ; cursor at col 5, row 0
      (nerimux/terminal/actions:cursor-nl s)
      (check-cursor s 0 1)))

  (it "cursor-nl-lnm-on-stacks-text-vertically"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-newline-mode s) t)
      (nerimux/terminal/actions:write-char-at-cursor s #\a)   ; col 0 row 0
      (nerimux/terminal/actions:cursor-nl s)                  ; LF + CR
      (nerimux/terminal/actions:write-char-at-cursor s #\b)   ; col 0 row 1
      (nerimux/terminal/actions:cursor-nl s)
      (nerimux/terminal/actions:write-char-at-cursor s #\c)   ; col 0 row 2
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 0 1)))
      (expect (char= #\c (char-at s 0 2)))))

  (it "cursor-nl-lnm-off-leaves-column-intact"
    (with-screen (s 10 5)
      (feed s "hi")                          ; cursor at col 2
      (nerimux/terminal/actions:cursor-nl s)
      (check-cursor s 2 1))))

(describe "terminal-suite/ind-esc-d-suite"

  (it "ind-via-parser-moves-down-preserving-column"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-newline-mode s) t)
      (feed s "hello")                   ; cursor at col 5, row 0
      (feed s (esc "D"))                 ; ESC D = IND = cursor-lf (not cursor-nl)
      (check-cursor s 5 1)))

  (it "ind-via-parser-at-scroll-bottom-scrolls"
    (with-screen (s 5 3)
      (feed s "XXXXX")
      (nerimux/terminal/actions:set-cursor s 0 2)   ; last row
      (feed s (esc "D"))                             ; IND
      (expect (<= (screen-cursor-y s) 2)))))

(describe "terminal-suite/bce-background-suite"

  (it "erase-region-bce-carries-current-background"
    (with-screen (s 5 3)
      (feed s "aaaaa")
      (feed s (esc "[42m"))           ; SGR 42 = green background
      (feed s (esc "[2J"))
      (let ((cell (screen-cell s 0 0)))
        (expect (= 2 (cell-bg cell))))))

  (it "scroll-up-one-exposed-row-carries-bce-background"
    (with-screen (s 5 3)
      (feed s (esc "[43m"))
      (nerimux/terminal/actions:scroll-up-one s)
      (let ((cell (screen-cell s 0 2)))
        (expect (= 3 (cell-bg cell))))))

  (it "erase-line-bce-carries-current-background"
    (with-screen (s 5 3)
      (feed s "abcde")                   ; write some content
      (feed s (esc "[44m"))              ; SGR 44 = blue background
      (feed s (esc "[1;1H"))             ; cursor home (col 0, row 0)
      (feed s (esc "[K"))                ; EL mode 0 (erase to end of line)
      (let ((cell (screen-cell s 0 0)))
        (expect (= 4 (cell-bg cell)))))))

(describe "terminal-suite/cursor-boundary-table-suite"

  (it-each ((cursor-up    :y  0  1  0  "cursor-up at row 0 stays at 0")
            (cursor-down  :y  9  1  9  "cursor-down at height-1 stays at height-1")
            (cursor-left  :x  0  1  0  "cursor-left at col 0 stays at 0")
            (cursor-right :x  9  1  9  "cursor-right at width-1 stays at width-1"))
      "cursor-boundary-clamping: ~*~*~*~*~*~A"
      (fn-sym axis init-val count expected desc)
    (declare (ignore desc))
    (with-screen (s 10 10)
      (if (eq axis :x)
          (setf (nerimux/terminal/types:screen-cursor-x s) init-val)
          (setf (nerimux/terminal/types:screen-cursor-y s) init-val))
      (funcall (symbol-function (find-symbol (symbol-name fn-sym)
                                             '#:nerimux/terminal/actions))
               s count)
      (let ((actual (if (eq axis :x)
                        (screen-cursor-x s)
                        (screen-cursor-y s))))
        (expect (= expected actual)))))

  (it-each ((5 :up   2 3 "up 2 from row 5 -> row 3")
            (5 :down 3 8 "down 3 from row 5 -> row 8")
            (5 :up   5 0 "up 5 from row 5 -> row 0 (clamp at scroll-top=0)")
            (5 :down 4 9 "down 4 from row 5 -> row 9 (clamp at scroll-bottom=9)"))
      "cursor-up-down: ~*~*~*~*~A"
      (init-y dir count expected desc)
    (declare (ignore desc))
    (with-screen (s 10 10)
      (setf (nerimux/terminal/types:screen-cursor-y s) init-y)
      (ecase dir
        (:up   (nerimux/terminal/actions:cursor-up   s count))
        (:down (nerimux/terminal/actions:cursor-down s count)))
      (expect (= expected (screen-cursor-y s))))))

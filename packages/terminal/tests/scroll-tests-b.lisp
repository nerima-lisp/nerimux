(in-package #:nerimux/test/terminal)

(describe "terminal-suite/direct-row-primitives"

  (it "copy-row-copies-all-cells"
    (with-screen (s 5 3)
      (feed s "hello")                       ; row 0 = "hello"
      (nerimux/terminal/actions::%copy-row s 1 0)  ; copy row 0 to row 1
      (expect (string= "hello" (row-string s 1)))))

  (it "clear-row-blanks-all-cells"
    (with-screen (s 5 3)
      (feed s "hello")                       ; row 0 = "hello"
      (nerimux/terminal/actions::%clear-row s 0)
      (expect (row-blank-p s 0))))

  (it "trim-scroll-history-caps-at-limit"
    (with-screen (s 5 3)
      (let ((cap nerimux/terminal:+max-scrollback-lines+))
        (setf (nerimux/terminal/types:screen-scrollback s)
              (loop repeat (+ cap 3)
                    collect (make-array 5 :initial-element
                                          (nerimux/terminal/types:blank-cell))))
        (nerimux/terminal/actions:trim-scroll-history s)
        (expect (<= (length (nerimux/terminal/types:screen-scrollback s)) cap))))))

(describe "terminal-suite/scrollback-cap-constant"
          (it "max-scrollback-lines-is-10000"
              (expect (= 10000 nerimux/terminal:+max-scrollback-lines+))))

(describe "terminal-suite/direct-action-erase"

  (it "erase-region-clears-span-across-rows"
    (with-screen (s 5 4)
      (feed s "aabbccddee")           ; rows 0 and 1 filled
      (nerimux/terminal/actions:erase-region s 3 0 1 1)
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\a (char-at s 1 0)))
      (expect (char= #\b (char-at s 2 0)))
      (expect (char= #\Space (char-at s 3 0)))
      (expect (char= #\Space (char-at s 4 0)))
      (expect (char= #\Space (char-at s 0 1)))
      (expect (char= #\Space (char-at s 1 1)))))

  (it "erase-display-mode-3-clears-scrollback"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2" "L3")
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))
      (nerimux/terminal/actions:erase-display s 3)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  (it "erase-line-mode-0-erases-to-end"
    (with-screen (s 10 5)
      (feed s "hello")
      (nerimux/terminal/actions:cursor-left s 3)   ; cursor at col 2
      (nerimux/terminal/actions:erase-line s 0)
      (expect (char= #\h (char-at s 0 0)))
      (expect (char= #\e (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\Space (char-at s 4 0))))))

(describe "terminal-suite/direct-decstbm"

  (it "decstbm-valid-region-sets-scroll-boundaries"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 1 3)
      (expect (= 1 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 3 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "decstbm-valid-region-homes-cursor"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:set-cursor s 3 3)
      (nerimux/terminal/actions:decstbm s 0 4)
      (check-cursor s 0 0)))

  (it "decstbm-equal-top-bottom-is-rejected"
    (with-screen (s 5 5)
      (let ((orig-top    (nerimux/terminal/types:screen-scroll-top s))
            (orig-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 2 2)  ; top = bottom = 2
        (expect (= orig-top    (nerimux/terminal/types:screen-scroll-top s)))
        (expect (= orig-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  (it "decstbm-inverted-region-is-rejected"
    (with-screen (s 5 5)
      (let ((orig-top    (nerimux/terminal/types:screen-scroll-top s))
            (orig-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 4 1)  ; top > bottom — invalid
        (expect (= orig-top    (nerimux/terminal/types:screen-scroll-top s)))
        (expect (= orig-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  (it "decstbm-out-of-range-clamped-to-screen"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s -5 99)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 4 (nerimux/terminal/types:screen-scroll-bottom s))))))

(defmacro with-5-row-scroll-region ((screen-var) &body body)
  "Bind SCREEN-VAR to a 5-row screen with rows labeled R0-R4 and scroll
   region restricted to rows 1-3.  Used by constrained-scroll tests."
  `(with-screen (,screen-var 5 5)
                (feed-lines ,screen-var "R0" "R1" "R2" "R3" "R4")
                (nerimux/terminal/actions:decstbm ,screen-var 1 3)
                ,@body))

(describe "terminal-suite/constrained-scroll"

  (it "scroll-up-one-respects-scroll-region"
    (with-5-row-scroll-region (s)
      (nerimux/terminal/actions:scroll-up-one s)
      (check-row s 0 "R0")
      (check-row s 4 "R4")))

  (it "scroll-down-one-respects-scroll-region"
    (with-5-row-scroll-region (s)
      (nerimux/terminal/actions:scroll-down-one s)
      (check-row s 0 "R0")
      (check-row s 4 "R4")
      (expect (row-blank-p s 1)))))

(describe "terminal-suite/scroll-dirty-flag"

  (it "scroll-up-and-down-one-mark-screen-dirty"
    (dolist (fn (list #'nerimux/terminal/actions:scroll-up-one
                      #'nerimux/terminal/actions:scroll-down-one))
      (with-screen (s 5 3)
        (screen-clear-dirty s)
        (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
        (funcall fn s)
        (expect (nerimux/terminal/types:screen-dirty-p s))))))

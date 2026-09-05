(in-package #:nerimux/test/terminal)

(defmacro with-scroll-region ((screen-var w h top bottom cy) &body body)
  "Bind SCREEN-VAR to a W×H screen with scroll region TOP..BOTTOM and cursor
   initially on row CY.  Used by scroll-region clamping and cursor-ri tests."
  `(with-screen (,screen-var ,w ,h)
                (setf (nerimux/terminal/types::screen-scroll-top ,screen-var) ,top
                      (nerimux/terminal/types::screen-scroll-bottom ,screen-var) ,bottom
                      (nerimux/terminal/types::screen-cursor-y ,screen-var) ,cy)
                ,@body))

(defmacro with-cursor-at ((screen-var w h x &optional (y 0)) &body body)
  "Bind SCREEN-VAR to a W×H screen with the cursor initially at column X,
   row Y (defaulting to row 0)."
  `(with-screen (,screen-var ,w ,h)
                (setf (nerimux/terminal/types:screen-cursor-x ,screen-var) ,x
                      (nerimux/terminal/types:screen-cursor-y ,screen-var) ,y)
                ,@body))

(describe "terminal-suite/scroll-region-clamp"

  (it "cursor-up-clamps-to-scroll-top"
    (with-scroll-region (s 10 10 3 7 6)
      (nerimux/terminal/actions::cursor-up s 100)
      (expect (= 3 (screen-cursor-y s)))
      (expect (/= 0 (screen-cursor-y s)))))

  (it "cursor-down-clamps-to-scroll-bottom"
    (with-scroll-region (s 10 10 3 7 4)
      (nerimux/terminal/actions::cursor-down s 100)
      (expect (= 7 (screen-cursor-y s)))
      (expect (/= 9 (screen-cursor-y s)))))

  (it "cursor-horizontal-clamping-table"
    (dolist (row (list (list 5 #'nerimux/terminal/actions::cursor-left  0 "cursor-left  clamps to 0")
                       (list 2 #'nerimux/terminal/actions::cursor-right 9 "cursor-right clamps to 9")))
      (destructuring-bind (init-x fn expected desc) row
        (declare (ignore desc))
        (with-cursor-at (s 10 10 init-x)
          (funcall fn s 100)
          (expect (= expected (screen-cursor-x s)))))))

  (it "cursor-up-down-respect-region-from-mid"
    (with-scroll-region (s 10 10 2 8 5)
      (nerimux/terminal/actions::cursor-up s 2)
      (expect (= 3 (screen-cursor-y s)))
      (nerimux/terminal/actions::cursor-down s 4)
      (expect (= 7 (screen-cursor-y s))))))

(describe "terminal-suite/set-cursor-suite"

  (it "set-cursor-table"
    (dolist (row '(( 3  7  3  7 "in-bounds: (3,7) → cursor at (3,7)")
                   (99  0  9  0 "x ≥ width → clamped to width-1=9")
                   ( 0 99  0  9 "y ≥ height → clamped to height-1=9")
                   (-5  3  0  3 "negative x → clamped to 0")))
      (destructuring-bind (x y expected-x expected-y desc) row
        (declare (ignore desc))
        (with-screen (s 10 10)
          (nerimux/terminal/actions:set-cursor s x y)
          (expect (= expected-x (screen-cursor-x s)))
          (expect (= expected-y (screen-cursor-y s))))))))

(describe "terminal-suite/direct-action-cursor"

  (it "cursor-bs-moves-left-and-clamps-at-zero"
    (with-screen (s 10 5)
      (feed s "abc")
      (nerimux/terminal/actions:cursor-bs s)
      (check-cursor s 2 0))
    (with-screen (s 10 5)
      (nerimux/terminal/actions:cursor-bs s)
      (check-cursor s 0 0)))

  (it "cursor-cr-resets-column"
    (with-screen (s 10 5)
      (feed s "hello")
      (nerimux/terminal/actions:cursor-cr s)
      (check-cursor s 0 0)))

  (it "cursor-lf-scrolls-at-bottom"
    (with-screen (s 5 3)
      (feed s "A")
      (nerimux/terminal/actions:cursor-lf s)
      (nerimux/terminal/actions:cursor-lf s) ; now at row 2 (bottom)
      (nerimux/terminal/actions:cursor-lf s) ; should scroll, not go to row 3
      (expect (<= (screen-cursor-y s) 2))))

  (it "cursor-ht-advances-to-next-tab-stop"
    (with-screen (s 20 5)
      (nerimux/terminal/actions:cursor-ht s)
      (check-cursor s 8 0)
      (nerimux/terminal/actions:cursor-ht s)
      (check-cursor s 16 0)
      (nerimux/terminal/actions:cursor-ht s)
      (check-cursor s 19 0)))


  (it "cursor-cht-count-table"
    (dolist (row '((2 16 "n=2: advance 2 stops → col 16")
                   (0  8 "n=0: treated as 1 stop → col 8")))
      (destructuring-bind (n expected desc) row
        (declare (ignore desc))
        (with-screen (s 40 5)
          (nerimux/terminal/actions:cursor-cht s n)
          (expect (= expected (screen-cursor-x s)))))))

  (it "cursor-cht-one-is-same-as-cursor-ht"
    (let ((s1 (make-screen 20 5))
          (s2 (make-screen 20 5)))
      (nerimux/terminal/actions:cursor-ht  s1)
      (nerimux/terminal/actions:cursor-cht s2 1)
      (expect (= (screen-cursor-x s1) (screen-cursor-x s2)))))


  (it "cursor-cbt-table"
    (dolist (row '((16  2  0 "from col 16, back 2 stops: 16→8→0")
                   ( 5 99  0 "large n clamps at col 0")
                   (16  0  8 "n=0 treated as 1: 16→8")))
      (destructuring-bind (start-col n expected desc) row
        (declare (ignore desc))
        (with-cursor-at (s 40 5 start-col)
          (nerimux/terminal/actions:cursor-cbt s n)
          (expect (= expected (screen-cursor-x s)))))))


  (it "hts-set-tab-stop-makes-cursor-ht-land-on-custom-stop"
    (with-cursor-at (s 40 5 3)
      (nerimux/terminal/actions:set-tab-stop s)        ; HTS at col 3
      (setf (nerimux/terminal/types:screen-cursor-x s) 0)
      (nerimux/terminal/actions:cursor-ht s)           ; HT from col 0
      (expect (= 3 (screen-cursor-x s)))))

  (it "tbc-3-clears-all-stops-so-ht-goes-to-last-column"
    (with-cursor-at (s 40 5 0)
      (nerimux/terminal/actions:clear-tab-stops s 3)   ; TBC 3 — clear all
      (nerimux/terminal/actions:cursor-ht s)
      (expect (= 39 (screen-cursor-x s)))))

  (it "tbc-0-clears-stop-at-cursor-column"
    (with-cursor-at (s 40 5 8)
      (nerimux/terminal/actions:clear-tab-stops s 0)   ; TBC 0 at col 8
      (setf (nerimux/terminal/types:screen-cursor-x s) 0)
      (nerimux/terminal/actions:cursor-ht s)
      (expect (= 16 (screen-cursor-x s)))))

  (it "esc-h-hts-sets-tab-stop-via-parser"
    (with-screen (s 40 5)
      (feed s (esc "[1;4H"))   ; CUP → col 4 (1-based) = col 3 (0-based)
      (feed s (esc "H"))       ; ESC H → HTS at col 3
      (feed s (esc "[1;1H"))   ; CUP → col 0
      (feed s (string (code-char 9)))  ; HT → custom stop 3
      (expect (= 3 (screen-cursor-x s)))))

  (it "csi-3-g-tbc-clears-all-stops-via-parser"
    (with-screen (s 40 5)
      (feed s (esc "[3g"))     ; CSI 3 g → TBC clear all
      (feed s (esc "[1;1H"))   ; cursor to col 0
      (feed s (string (code-char 9)))  ; HT → last column
      (expect (= 39 (screen-cursor-x s))))))

(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "selection-bounds-after-scroll-uses-virtual-rows"
    (let ((s (make-screen 4 3)))        ; 4 cols, 3 rows
      (feed-lines s "AAA" "BBB" "CCC" "DDD" "EEE")
      (nerimux/commands::copy-mode-enter s)
      (expect (= 0 (screen-copy-offset s)))
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 3))
      (nerimux/commands::copy-mode-begin-selection s)
      (expect (= 0 (nerimux/terminal/types:screen-copy-mark-offset s)))
      (nerimux/commands::copy-mode-scroll s 1)
      (expect (= 1 (screen-copy-offset s)))
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      (multiple-value-bind (start-vrow end-vrow start-col end-col)
          (nerimux/commands::%selection-bounds s)
        (declare (ignore start-col end-col))
        (expect (= 1 start-vrow))
        (expect (= 4 end-vrow)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (and text (search "BBB" text)))
        (expect (and text (search "EEE" text)))))))

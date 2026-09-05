(in-package #:nerimux/test/commands)

(describe "commands-suite"

  (it "copy-mode-exit-resets-rect-select"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t)
      (nerimux/commands::copy-mode-exit s)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)))


  (it "copy-mode-yank-rectangle-uses-fixed-columns"
    (let ((s (make-screen 10 5)))
      (feed s (format nil "abcde~C~CABCDE" #\Return #\Linefeed))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t
            (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) (cons 0 1)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 3))
      (nerimux/commands::copy-mode-yank s)
      (let* ((q   (nerimux/terminal/types:screen-clipboard-queue s))
             (seq (first q))
             (expected (nerimux/terminal/parser:osc52-clipboard-sequence
                        (format nil "bc~%BC"))))
        (expect (= 1 (length q)))
        (expect (string= expected seq))))))

(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "rectangle-selection-text-returns-nil-when-no-selection"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) nil)
      (expect (null (nerimux/commands::%rectangle-selection-text s)))))

  (it "rectangle-selection-text-returns-nil-when-mark-nil"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) nil
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 5))
      (expect (null (nerimux/commands::%rectangle-selection-text s)))))

  (it "rectangle-selection-text-single-row"
    (let ((s (make-screen 20 5)))
      (feed s "hello world")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting    s) t
            (nerimux/terminal/types:screen-copy-mark         s) (cons 0 0)
            (nerimux/terminal/types:screen-copy-cursor       s) (cons 0 5))
      (let ((text (nerimux/commands::%rectangle-selection-text s)))
        (expect (stringp text))
        (expect (string= "hello" text)))))

  (it "rectangle-selection-text-multi-row-fixed-columns"
    (let ((s (make-screen 10 5)))
      (feed s (format nil "abcde~C~CABCDE" #\Return #\Linefeed))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) (cons 0 1)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 3))
      (let ((text (nerimux/commands::%rectangle-selection-text s)))
        (expect (stringp text))
        (expect (search "bc" text))
        (expect (search "BC" text))
        (expect (find #\Newline text)))))


  )

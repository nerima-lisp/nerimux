(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "selection-text-returns-nil-when-no-selection"
    (let ((s (copy-mode-screen :w 20 :h 5)))
      (expect (null (nerimux/commands::%selection-text s)))))

  (it "selection-text-returns-nil-when-mark-nil"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :selecting t
                               :cursor (cons 0 5))))
      (expect (null (nerimux/commands::%selection-text s)))))

  (it "selection-text-single-row-returns-correct-text"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :content "hello world"
                               :mark (cons 0 0)
                               :cursor (cons 0 5)
                               :selecting t)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (stringp text))
        (expect (string= "hello" text)))))

  (it "selection-text-multi-row-returns-newline-joined-text"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :content (format nil "abc~C~Cdef" #\Return #\Linefeed)
                               :mark (cons 0 0)
                               :cursor (cons 1 3)
                               :selecting t)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (stringp text))
        (expect (find #\Newline text))
        (expect (string= (format nil "abc~%def") text)))))

  (it "selection-text-reversed-mark-cursor-order"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :content "hello world"
                               :mark (cons 0 5)
                               :cursor (cons 0 0)
                               :selecting t)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (stringp text))
        (expect (string= "hello" text))))))

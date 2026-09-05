(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "copy-mode-begin-selection-sets-selecting-flag"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 5))
      (nerimux/commands::copy-mode-begin-selection s)
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-truthy)
      (expect (equal (cons 2 5) (nerimux/terminal/types:screen-copy-mark s)))))

  (it "copy-mode-begin-selection-noop-outside-copy-mode"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-begin-selection s)
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)))

  (it "copy-mode-yank-enqueues-osc52-unconditionally"
    (let ((s (make-screen 20 5)))
      (feed s "hello")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark   s) (cons 0 0)
            (nerimux/terminal/types:screen-copy-cursor s) (cons 0 5))
      (nerimux/commands::copy-mode-yank s)
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)
      (let ((q (nerimux/terminal/types:screen-clipboard-queue s)))
        (expect (= 1 (length q)))
        (expect (search "]52;c;" (first q)))
        (expect (search "aGVsbG8=" (first q))))))

  (it "copy-mode-yank-noop-when-no-selection"
    (let ((s (copy-mode-screen :content "data")))
      (setf (nerimux/terminal/types:screen-copy-selecting s) nil)
      (nerimux/commands::copy-mode-yank s)
      (expect (null (nerimux/terminal/types:screen-clipboard-queue s)))))

  (it "copy-mode-cancel-selection-clears-all-state"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) (cons 1 2)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 5))
      (nerimux/commands::copy-mode-cancel-selection s)
      (expect (null (nerimux/terminal/types:screen-copy-mark s)))
      (expect (null (nerimux/terminal/types:screen-copy-cursor s)))
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy))))

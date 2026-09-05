(in-package #:nerimux/test/commands)

(describe "commands-suite"

  (it "shift-line-wrapped-up-moves-flags"
    (let ((s (make-screen 5 4)))
      (nerimux/terminal/types:%mark-line-wrapped s 2)        ; row 2 wraps
      (nerimux/terminal/types:%shift-line-wrapped-up s 0 3)  ; scroll region rows 0..3
      (expect (nerimux/terminal/types:%line-wrapped-p s 1) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-falsy)))

  (it "line-wrapped-flag-cleared-on-erase"
    (let ((s (make-screen 5 3)))
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-truthy)
      (nerimux/terminal/actions:erase-region s 0 0 4 0)      ; erase row 0
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy))))

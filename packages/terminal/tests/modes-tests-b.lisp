(in-package #:nerimux/test/terminal)

(describe "terminal-suite/set-cursor-shape-suite"

  (it-each ((0 0 "default blinking block")
            (1 1 "blinking block")
            (2 2 "steady block")
            (3 3 "blinking underline")
            (4 4 "steady underline")
            (5 5 "blinking bar")
            (6 6 "steady bar"))
      "set-cursor-shape-stores-valid-values: ~*~*~A"
      (input expected desc)
    (declare (ignore desc))
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor-shape s input)
      (expect (= expected (nerimux/terminal/types:screen-cursor-shape s)))))

  (it "set-cursor-shape-clamps-above-six-to-six"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor-shape s 99)
      (expect (= 6 (nerimux/terminal/types:screen-cursor-shape s)))))

  (it "set-cursor-shape-clamps-below-zero-to-zero"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor-shape s -1)
      (expect (= 0 (nerimux/terminal/types:screen-cursor-shape s))))))

(describe "terminal-suite/bell-pending-suite"

  (it "set-bell-pending-sets-flag"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (nerimux/terminal/actions:set-bell-pending s)
      (expect (nerimux/terminal/types:screen-bell-pending s))))

  (it "screen-consume-bell-returns-true-and-clears-flag"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-bell-pending s)
      (let ((result (nerimux/terminal/types:screen-consume-bell s)))
        (expect result :to-be-truthy)
        (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy))))

  (it "screen-consume-bell-returns-nil-when-not-pending"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy)))

  (it "bell-byte-sets-pending-via-emulator"
    (with-screen (s 10 5)
      (screen-process-bytes s (vector 7))  ; BEL = 0x07
      (expect (nerimux/terminal/types:screen-bell-pending s)))))

(describe "terminal-suite/set-charset-set-title-suite"

  (it "set-charset-stores-ascii-keyword"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-charset s) :dec-graphics)
      (nerimux/terminal/actions:designate-charset s :g0 :ascii)
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "set-charset-stores-dec-graphics-keyword"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  (it "set-screen-title-stores-string"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "my-window")
      (expect (string= "my-window" (nerimux/terminal/types:screen-title s)))))

  (it "set-screen-title-stores-empty-string"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "first")
      (nerimux/terminal/actions:set-screen-title s "")
      (expect (string= "" (nerimux/terminal/types:screen-title s)))))

  (it "set-screen-title-via-osc-sequence"
    (with-screen (s 20 5)
      (feed s (format nil "~C]0;hello~C" #\Escape (code-char 7)))
      (expect (string= "hello" (nerimux/terminal/types:screen-title s))))))

(describe "terminal-suite/reset-terminal-modes-suite"

  (it "reset-terminal-modes-restores-flags"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cursor-visible s) nil
            (nerimux/terminal/types:screen-autowrap s)        nil
            (nerimux/terminal/types:screen-charset s)         :dec-graphics)
      (nerimux/terminal/actions:reset-terminal-modes s)
      (expect (nerimux/terminal/types:screen-cursor-visible s))
      (expect (nerimux/terminal/types:screen-autowrap s))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "reset-terminal-modes-restores-scroll-region-to-full-screen"
    (with-screen (s 10 8)
      (setf (nerimux/terminal/types:screen-scroll-top    s) 2
            (nerimux/terminal/types:screen-scroll-bottom s) 5)
      (nerimux/terminal/actions:reset-terminal-modes s)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 7 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "reset-terminal-modes-does-not-clear-cells"
    (with-screen (s 10 5)
      (feed s "hello")
      (nerimux/terminal/actions:reset-terminal-modes s)
      (expect (char= #\h (char-at s 0 0))))))

(describe "terminal-suite/alt-screen-direct-suite"

  (it "enter-alt-screen-is-noop-when-already-active"
    (with-screen (s 10 5)
      (feed s "primary")
      (nerimux/terminal/actions:enter-alt-screen s)    ; first entry — saves grid
      (let ((saved-alt-cells (nerimux/terminal/types:screen-alt-cells s)))
        (nerimux/terminal/actions:enter-alt-screen s)  ; second call — no-op
        (expect (eq saved-alt-cells (nerimux/terminal/types:screen-alt-cells s))))))

  (it "exit-alt-screen-clears-to-blank-when-no-saved-grid"
    (with-screen (s 10 5)
      (feed s "hello")
      (nerimux/terminal/actions:exit-alt-screen s)
      (dotimes (y 5)
        (expect (row-blank-p s y))))))

(describe "terminal-suite/alt-screen-content-suite"

  (it "enter-alt-screen-installs-blank-grid"
    (with-screen (s 10 5)
      (feed s "primary")
      (nerimux/terminal/actions:enter-alt-screen s)
      (dotimes (y 5)
        (expect (row-blank-p s y)))))

  (it "exit-alt-screen-restores-primary-cursor-position"
    (with-screen (s 20 10)
      (nerimux/terminal/actions:set-cursor s 7 3)
      (nerimux/terminal/actions:enter-alt-screen s)
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:exit-alt-screen s)
      (check-cursor s 7 3))))

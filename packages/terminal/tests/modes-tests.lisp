(in-package #:nerimux/test/terminal)

(describe "terminal-suite/modes"

  (it "ris-clears-screen-and-homes-cursor"
    (with-screen (s 10 5)
      (feed s "hello")
      (feed s (esc "[3;3H"))
      (feed s (esc "c"))
      (check-cursor s 0 0)
      (expect (row-blank-p s 0))
      (expect (row-blank-p s 1))))

  (it "alt-screen-no-crash"
    (with-screen (s 10 5)
      (feed s "primary")
      (feed s (esc "[?1049h"))
      (feed s "alt")
      (feed s (esc "[?1049l"))
      (expect (integerp (screen-cursor-x s)))
      (expect (integerp (screen-cursor-y s)))))

  (it "alt-screen-save-restore"
    (with-screen (s 10 5)
      (feed s "hello")
      (feed s (esc "[?1049h"))
      (feed s "ALT")
      (feed s (esc "[?1049l"))
      (expect (string= "hello" (row-string s 0 :end 5)))))

  (it "esc-1049h-enters-alt-buffer"
    (with-screen (s 10 5)
      (feed s "hello")
      (feed s (esc "[?1049h"))
      (expect (not (null (nerimux/terminal/types::screen-alt-cells s))))
      (feed s (esc "[?1049l"))
      (expect (string= "hello" (row-string s 0 :end 5)))))

  (it "alt-screen-1047-save-restore"
    (with-screen (s 10 5)
      (feed s "hello")
      (feed s (esc "[?1047h"))
      (feed s "ALT")
      (feed s (esc "[?1047l"))
      (expect (string= "hello" (row-string s 0 :end 5)))))

  (it "cursor-1048-save-restore"
    (with-screen (s 20 5)
      (feed s (esc "[3;6H"))
      (feed s (esc "[?1048h"))
      (feed s (esc "[1;1H"))
      (feed s (esc "[?1048l"))
      (check-cursor s 5 2)))

  (it "decsc-decrc"
    (with-screen (s 20 5)
      (feed s (esc "[3;6H"))
      (feed s (esc "[31;1m"))
      (feed s (esc "7"))
      (feed s (esc "[1;1H"))
      (feed s (esc "[0m"))
      (feed s (esc "8"))
      (check-cursor s 5 2)
      (feed s "X")
      (expect (= 1 (fg-at s 5 2)))
      (expect (logbitp 0 (attrs-at s 5 2)))))

  (it "decrc-without-save-homes-cursor"
    (with-screen (s 20 5)
      (feed s (esc "[3;6H"))
      (feed s (esc "8"))
      (check-cursor s 0 0)))

  (it "decsc-decrc-preserves-g0-charset"
    (with-screen (s 20 5)
      (feed s (esc "(0"))
      (feed s (esc "7"))
      (feed s (esc "(B"))
      (expect (eq :ascii (nerimux/terminal/types:screen-g0-charset s)))
      (feed s (esc "8"))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-g0-charset s)))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  (it "decsc-decrc-preserves-active-charset"
    (with-screen (s 20 5)
      (feed s (esc ")0"))
      (feed s (string (code-char #x0E)))
      (feed s (esc "7"))
      (feed s (string (code-char #x0F)))
      (expect (eq :g0 (nerimux/terminal/types:screen-active-g s)))
      (feed s (esc "8"))
      (expect (eq :g1 (nerimux/terminal/types:screen-active-g s)))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  (it "decsc-decrc-preserves-origin-mode"
    (with-screen (s 20 5)
      (feed s (esc "[?6h"))
      (feed s (esc "7"))
      (feed s (esc "[?6l"))
      (expect (not (nerimux/terminal/types:screen-origin-mode s)))
      (feed s (esc "8"))
      (expect (nerimux/terminal/types:screen-origin-mode s))))

  (it "decrc-without-save-resets-charset-and-origin-mode"
    (with-screen (s 20 5)
      (feed s (esc "(0"))
      (feed s (esc "[?6h"))
      (feed s (esc "8"))
      (expect (eq :ascii (nerimux/terminal/types:screen-g0-charset s)))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))
      (expect (not (nerimux/terminal/types:screen-origin-mode s))))))

(describe "terminal-suite/direct-modes-suite"

  (it "ris-action-clears-and-homes-cursor"
    (with-screen (s 10 5)
      (feed s "hello world")
      (nerimux/terminal/actions:set-cursor s 5 3)
      (nerimux/terminal/actions:dec-pm-reset s '(25))
      (nerimux/terminal/actions:ris-action s)
      (check-cursor s 0 0)
      (expect (row-blank-p s 0))
      (expect (row-blank-p s 3))
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 4 (nerimux/terminal/types:screen-scroll-bottom s)))
      (expect (nerimux/terminal/types:screen-cursor-visible s))))

  (it "save-and-restore-cursor"
    (with-screen (s 20 10)
      (nerimux/terminal/actions:set-cursor s 7 4)
      (feed s (format nil "~C[31;1m" #\Escape))
      (nerimux/terminal/actions:save-cursor s)
      (nerimux/terminal/actions:set-cursor s 0 0)
      (feed s (format nil "~C[0m" #\Escape))
      (nerimux/terminal/actions:restore-cursor s)
      (check-cursor s 7 4)
      (expect (= 1 (nerimux/terminal/types:screen-cur-fg s)))))

  (it "restore-cursor-without-save-homes-cursor"
    (with-screen (s 20 10)
      (nerimux/terminal/actions:set-cursor s 9 5)
      (nerimux/terminal/actions:restore-cursor s)
      (check-cursor s 0 0)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s)))))

  (it "dec-pm-set-1049-enters-alt-screen"
    (with-screen (s 10 5)
      (feed s "primary")
      (nerimux/terminal/actions:dec-pm-set s '(1049))
      (expect (not (null (nerimux/terminal/types:screen-alt-cells s))))
      (check-cursor s 0 0)
      (expect (row-blank-p s 0))))

  (it "dec-pm-reset-1049-exits-alt-screen"
    (with-screen (s 10 5)
      (feed s "primary")
      (nerimux/terminal/actions:dec-pm-set   s '(1049))
      (feed s "alt content")
      (nerimux/terminal/actions:dec-pm-reset s '(1049))
      (expect (string= "primary" (row-string s 0 :end 7)))
      (expect (null (nerimux/terminal/types:screen-alt-cells s)))))

  (it "dec-pm-unknown-mode-is-silently-ignored"
    (with-screen (s 10 5)
      (feed s "hello")
      (finishes (nerimux/terminal/actions:dec-pm-set   s '(9999 42 0)))
      (finishes (nerimux/terminal/actions:dec-pm-reset s '(9999 42 0)))
      (check-row s 0 "hello")))

  (it "dec-pm-mode-6-origin-mode-set-and-reset"
    (with-screen (s 20 5)
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-falsy)
      (nerimux/terminal/actions:dec-pm-set s '(6))
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-truthy)
      (nerimux/terminal/actions:dec-pm-reset s '(6))
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-falsy)))

  (it "dec-pm-accepted-no-op-modes-and-legacy-alt-screen"
    (with-screen (s 20 5)
      (nerimux/terminal/actions:dec-pm-set s '(2026 2048 12))
      (nerimux/terminal/actions:dec-pm-reset s '(2026 2048 12))
      (expect (null (nerimux/terminal/types:screen-alt-cells s)))
      (feed s "primary")
      (nerimux/terminal/actions:dec-pm-set s '(47))
      (expect (not (null (nerimux/terminal/types:screen-alt-cells s))))
      (feed s "alt")
      (nerimux/terminal/actions:dec-pm-reset s '(47))
      (expect (null (nerimux/terminal/types:screen-alt-cells s)))
      (expect (string= "primary" (row-string s 0 :end 7)))))

  (it "dectcem-hide-and-show"
    (with-screen (s 20 5)
      (expect (nerimux/terminal/types:screen-cursor-visible s))
      (feed s (esc "[?25l"))
      (expect (nerimux/terminal/types:screen-cursor-visible s) :to-be-falsy)
      (feed s (esc "[?25h"))
      (expect (nerimux/terminal/types:screen-cursor-visible s))))

  (it "dectcem-dec-pm-direct"
    (with-screen (s 20 5)
      (setf (nerimux/terminal/types:screen-cursor-visible s) nil)
      (nerimux/terminal/actions:dec-pm-set s '(25))
      (expect (nerimux/terminal/types:screen-cursor-visible s))
      (nerimux/terminal/actions:dec-pm-reset s '(25))
      (expect (nerimux/terminal/types:screen-cursor-visible s) :to-be-falsy)))

  (it "make-blank-cells-creates-blank-grid"
    (let ((cells (nerimux/terminal/types::%make-blank-cells 6)))
      (expect (= 6 (length cells)))
      (expect (every (lambda (c) (char= #\Space (cell-char c))) cells)))))

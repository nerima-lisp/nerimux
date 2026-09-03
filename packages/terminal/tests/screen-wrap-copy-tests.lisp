(in-package #:nerimux/test/terminal)

(describe "terminal-suite/wrapped-rows-slot-suite"

  (it "screen-wrapped-rows-slot-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-wrapped-rows s)))))

  (it "screen-wrapped-rows-lazily-allocated-on-first-mark"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (let ((table (nerimux/terminal/types:screen-wrapped-rows s)))
        (expect (hash-table-p table))))))

(describe "terminal-suite/mark-line-wrapped-suite"

  (it "mark-line-wrapped-marks-specified-row"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 2)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-truthy)))

  (it "line-wrapped-p-returns-false-for-unmarked-row"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy)))

  (it "mark-line-wrapped-only-marks-specified-row"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 1)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 1) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-falsy)))

  (it "mark-line-wrapped-multiple-rows"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (nerimux/terminal/types:%mark-line-wrapped s 3)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 1) :to-be-falsy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 3) :to-be-truthy))))

(describe "terminal-suite/clear-all-line-wrapped-suite"

  (it "clear-all-line-wrapped-removes-all-flags"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (nerimux/terminal/types:%mark-line-wrapped s 1)
      (nerimux/terminal/types:%mark-line-wrapped s 4)
      (nerimux/terminal/types:%clear-all-line-wrapped s)
      (dotimes (y 5)
        (expect (nerimux/terminal/types:%line-wrapped-p s y) :to-be-falsy))))

  (it "clear-all-line-wrapped-on-fresh-screen-is-noop"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-wrapped-rows s)))
      (finishes (nerimux/terminal/types:%clear-all-line-wrapped s))
      (expect (null (nerimux/terminal/types:screen-wrapped-rows s))))))

(describe "terminal-suite/shift-line-wrapped-up-suite"

  (it "shift-line-wrapped-up-moves-flags-in-region"
    (with-screen (s 10 6)
      (nerimux/terminal/types:%mark-line-wrapped s 2)
      (nerimux/terminal/types:%mark-line-wrapped s 3)
      (nerimux/terminal/types:%mark-line-wrapped s 4)
      (nerimux/terminal/types:%shift-line-wrapped-up s 1 5)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 1) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 3) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 4) :to-be-falsy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 5) :to-be-falsy)))

  (it "shift-line-wrapped-up-preserves-outside-region"
    (with-screen (s 10 8)
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (nerimux/terminal/types:%mark-line-wrapped s 6)
      (nerimux/terminal/types:%shift-line-wrapped-up s 2 5)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 6) :to-be-truthy)))

  (it "shift-line-wrapped-up-noop-when-no-table"
    (with-screen (s 10 5)
      (finishes (nerimux/terminal/types:%shift-line-wrapped-up s 0 4))
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy))))

(define-boolean-slot-tests
  nerimux/terminal/types:screen-insert-mode
  screen-insert-mode-suite
  (feed s (esc "[4h"))   ; CSI 4 h — IRM set (insert mode on)
  (feed s (esc "[4l"))   ; CSI 4 l — IRM reset (replace mode)
  :suite-description "screen-insert-mode: defaults NIL, CSI 4h enables, CSI 4l disables")

(define-boolean-slot-tests
  nerimux/terminal/types:screen-newline-mode
  screen-newline-mode-suite
  (feed s (esc "[20h"))  ; CSI 20 h — LNM set
  (feed s (esc "[20l"))  ; CSI 20 l — LNM reset
  :suite-description "screen-newline-mode: defaults NIL, CSI 20h enables, CSI 20l disables")

(define-boolean-slot-tests
  nerimux/terminal/types:screen-reverse-screen
  screen-reverse-screen-suite
  (feed s (esc "[?5h"))  ; ESC[?5h — DECSCNM set (reverse video on)
  (feed s (esc "[?5l"))  ; ESC[?5l — DECSCNM reset
  :suite-description "screen-reverse-screen: defaults NIL, ESC[?5h enables, ESC[?5l disables")

(describe "terminal-suite/copy-search-direction-suite"

  (it "screen-copy-search-direction-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-copy-search-direction s)))))

  (it "screen-copy-search-direction-can-be-set-forward"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-search-direction s) :forward)
      (expect (eq :forward (nerimux/terminal/types:screen-copy-search-direction s)))))

  (it "screen-copy-search-direction-can-be-set-backward"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-search-direction s) :backward)
      (expect (eq :backward (nerimux/terminal/types:screen-copy-search-direction s)))))

  (it "screen-copy-search-direction-can-be-cleared"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-search-direction s) :forward)
      (setf (nerimux/terminal/types:screen-copy-search-direction s) nil)
      (expect (null (nerimux/terminal/types:screen-copy-search-direction s))))))

(describe "terminal-suite/copy-rect-select-suite"

  (it "screen-copy-rect-select-p-defaults-nil"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)))

  (it "screen-copy-rect-select-p-can-be-set-and-cleared"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-truthy)
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) nil)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy))))

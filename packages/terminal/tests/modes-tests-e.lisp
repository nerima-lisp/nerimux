(in-package #:nerimux/test/terminal)

(describe "terminal-suite/decstr-action-direct-suite"

  (it "decstr-action-resets-modes-without-clearing-screen"
    (with-screen (s 10 5)
      (feed s "hello")
      (setf (nerimux/terminal/types:screen-insert-mode s)    t
            (nerimux/terminal/types:screen-autowrap s)       nil
            (nerimux/terminal/types:screen-cursor-visible s) nil)
      (nerimux/terminal/actions:set-cursor s 5 0)
      (nerimux/terminal/actions:decstr-action s)
      (expect (not (nerimux/terminal/types:screen-insert-mode s)))
      (expect (nerimux/terminal/types:screen-autowrap s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-cursor-visible s) :to-be-truthy)
      (expect (string= "hello" (row-string s 0 :end 5)))
      (expect (= 5 (screen-cursor-x s)))))

  (it "decstr-action-resets-sgr-pen"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cur-attrs s) #x01
            (nerimux/terminal/types:screen-cur-fg    s) 1)
      (nerimux/terminal/actions:decstr-action s)
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))))

  (it "decstr-action-clears-app-cursor-keys-bracketed-paste-and-saved-cursor"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-app-cursor-keys s) t
            (nerimux/terminal/types:screen-bracketed-paste s) t)
      (nerimux/terminal/actions:save-cursor s)
      (nerimux/terminal/actions:decstr-action s)
      (expect (nerimux/terminal/types:screen-app-cursor-keys s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-bracketed-paste s) :to-be-falsy)
      (expect (null (nerimux/terminal/types:screen-saved-cursor s))))))

(describe "terminal-suite/decaln-action-direct-suite"

  (it "decaln-action-fills-every-cell-with-e"
    (with-screen (s 5 3)
      (nerimux/terminal/actions:decaln-action s)
      (dotimes (y 3)
        (dotimes (x 5)
          (expect (char= #\E (char-at s x y)))))))

  (it "decaln-action-homes-the-cursor"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor s 7 3)
      (nerimux/terminal/actions:decaln-action s)
      (check-cursor s 0 0)))

  (it "decaln-action-marks-screen-dirty"
    (with-screen (s 5 3)
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
      (nerimux/terminal/actions:decaln-action s)
      (expect (nerimux/terminal/types:screen-dirty-p s))))

  (it "decaln-action-overwrites-existing-content"
    (with-screen (s 5 3)
      (feed s "hello")
      (nerimux/terminal/actions:decaln-action s)
      (expect (char= #\E (char-at s 0 0))))))

(describe "terminal-suite/ansi-mode-direct-suite"

  (it "set-ansi-mode-4-sets-insert-mode"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-falsy)
      (nerimux/terminal/actions:set-ansi-mode s '(4))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-truthy)))

  (it "reset-ansi-mode-4-clears-insert-mode"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-insert-mode s) t)
      (nerimux/terminal/actions:reset-ansi-mode s '(4))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-falsy)))

  (it "set-ansi-mode-20-sets-newline-mode"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-ansi-mode s '(20))
      (expect (nerimux/terminal/types:screen-newline-mode s) :to-be-truthy)))

  (it "reset-ansi-mode-20-clears-newline-mode"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-newline-mode s) t)
      (nerimux/terminal/actions:reset-ansi-mode s '(20))
      (expect (nerimux/terminal/types:screen-newline-mode s) :to-be-falsy)))

  (it "set-ansi-mode-accepts-multiple-params-in-one-call"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-ansi-mode s '(4 20))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-newline-mode s) :to-be-truthy)))

  (it "ansi-mode-unknown-param-is-silently-ignored"
    (with-screen (s 10 5)
      (finishes (nerimux/terminal/actions:set-ansi-mode s '(9999)))
      (finishes (nerimux/terminal/actions:reset-ansi-mode s '(9999)))
      (expect (nerimux/terminal/types:screen-insert-mode s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-newline-mode s) :to-be-falsy))))

(describe "terminal-suite/title-stack-direct-suite"

  (it "push-title-stack-prepends-current-title"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "one")
      (nerimux/terminal/actions:push-title-stack s)
      (expect (equal '("one") (nerimux/terminal/types:screen-title-stack s)))))

  (it "push-title-stack-multiple-pushes-newest-first"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "one")
      (nerimux/terminal/actions:push-title-stack s)
      (nerimux/terminal/actions:set-screen-title s "two")
      (nerimux/terminal/actions:push-title-stack s)
      (expect (equal '("two" "one") (nerimux/terminal/types:screen-title-stack s)))))

  (it "push-title-stack-discards-oldest-past-max-depth"
    (with-screen (s 10 5)
      (dotimes (i (1+ nerimux/terminal/types:+title-stack-max-depth+))
        (nerimux/terminal/actions:set-screen-title s (format nil "t~D" i))
        (nerimux/terminal/actions:push-title-stack s))
      (expect (= nerimux/terminal/types:+title-stack-max-depth+
                 (length (nerimux/terminal/types:screen-title-stack s))))))

  (it "pop-title-stack-restores-and-removes-top-entry"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "original")
      (nerimux/terminal/actions:push-title-stack s)
      (nerimux/terminal/actions:set-screen-title s "changed")
      (nerimux/terminal/actions:pop-title-stack s)
      (expect (string= "original" (nerimux/terminal/types:screen-title s)))
      (expect (null (nerimux/terminal/types:screen-title-stack s)))))

  (it "pop-title-stack-on-empty-stack-is-noop"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "kept")
      (finishes (nerimux/terminal/actions:pop-title-stack s))
      (expect (string= "kept" (nerimux/terminal/types:screen-title s))))))

(describe "terminal-suite/osc-default-color-reset-direct-suite"

  (it "reset-osc-default-fg-restores-constant"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-osc-default-fg s) #x123456)
      (nerimux/terminal/actions:reset-osc-default-fg s)
      (expect (= nerimux/terminal/types:+osc-default-fg+
                 (nerimux/terminal/types:screen-osc-default-fg s)))))

  (it "reset-osc-default-bg-restores-constant"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-osc-default-bg s) #x654321)
      (nerimux/terminal/actions:reset-osc-default-bg s)
      (expect (= nerimux/terminal/types:+osc-default-bg+
                 (nerimux/terminal/types:screen-osc-default-bg s))))))

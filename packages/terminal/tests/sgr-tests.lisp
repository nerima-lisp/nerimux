(in-package #:nerimux/test/terminal)

(describe "terminal-suite/sgr"

  (it "sgr-foreground-table"
    (loop for code from 31 to 37
          for expected-fg from 1 to 7
          do (with-screen (s 10 2)
               (feed s (esc "[~DmX" code))
               (expect (= expected-fg (fg-at s 0 0))))))

  (it "sgr-background-table"
    (loop for code from 41 to 47
          for expected-bg from 1 to 7
          do (with-screen (s 10 2)
               (feed s (esc "[~DmX" code))
               (expect (= expected-bg (bg-at s 0 0))))))

  (it "sgr-bright-foreground-table"
    (loop for code from 90 to 97
          for expected-fg from 8 to 15
          do (with-screen (s 10 2)
               (feed s (esc "[~DmX" code))
               (expect (= expected-fg (fg-at s 0 0))))))

  (it-each (("[1mX" 0 "SGR 1 -> bold (bit 0)")
            ("[2mX" 1 "SGR 2 -> dim (bit 1)")
            ("[7mX" 2 "SGR 7 -> reverse (bit 2)")
            ("[4mX" 3 "SGR 4 -> underline (bit 3)")
            ("[5mX" 4 "SGR 5 -> blink (bit 4)")
            ("[8mX" 6 "SGR 8 -> conceal (bit 6)")
            ("[9mX" 7 "SGR 9 -> strikethrough (bit 7)"))
      "sgr-basic-attrs-set: ~*~*~A"
      (seq bit desc)
    (declare (ignore desc))
    (with-screen (s 10 2)
      (feed s (esc seq))
      (expect (logbitp bit (attrs-at s 0 0)))))

  (it-each (("[8mX" "[28mY" 6 "SGR 28 clears conceal (bit 6)")
            ("[9mX" "[29mY" 7 "SGR 29 clears strikethrough (bit 7)"))
      "sgr-attr-clear: ~*~*~*~A"
      (set-seq clear-seq bit desc)
    (declare (ignore desc))
    (with-screen (s 10 2)
      (feed s (esc set-seq))
      (feed s (esc clear-seq))
      (expect (logbitp bit (attrs-at s 1 0)) :to-be-falsy)))

  (it "sgr-reset"
    (with-screen (s 10 2)
      (feed s (esc "[31;1mX"))
      (feed s (esc "[0mY"))
      (check-cell s 1 0 :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)))

  (it "sgr-default-fg-39"
    (with-screen (s 10 2)
      (feed s (esc "[31m"))    ; fg → 1 (red)
      (feed s (esc "[39mX"))   ; fg → default sentinel
      (check-sgr-state s :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)
      (expect (= nerimux/terminal/types:+default-color+ (fg-at s 0 0)))))

  (it "sgr-default-bg-49"
    (with-screen (s 10 2)
      (feed s (esc "[42m"))    ; bg → 2 (green)
      (feed s (esc "[49mX"))   ; bg → default sentinel
      (check-sgr-state s :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)
      (expect (= nerimux/terminal/types:+default-color+ (bg-at s 0 0)))))

  (it "sgr-bold-dim-off-22"
    (with-screen (s 10 2)
      (feed s (esc "[1;2m"))   ; bold + dim on
      (feed s (esc "[22mX"))   ; both off
      (expect (zerop (logand (attrs-at s 0 0) #b011)))))

  (it "sgr-compound"
    (with-screen (s 10 2)
      (feed s (esc "[1;31;42mX"))
      (expect (= 1 (fg-at s 0 0)))
      (expect (= 2 (bg-at s 0 0)))
      (expect (logbitp 0 (attrs-at s 0 0)))))

  (it "sgr-bright-red"
    (with-screen (s 10 2)
      (feed s (esc "[91mR"))
      (expect (= 9 (fg-at s 0 0)))))

  (it "sgr-italic-sets-italic-bit-not-dim"
    (with-screen (s 10 2)
      (feed s (esc "[3mX"))
      (expect (logbitp 5 (attrs-at s 0 0)))
      (expect (logbitp 1 (attrs-at s 0 0)) :to-be-falsy)))

  (it "sgr-italic-off-23"
    (with-screen (s 10 2)
      (feed s (esc "[3;1mX"))  ; italic + bold on
      (feed s (esc "[23mY"))   ; italic off
      (expect (logbitp 5 (attrs-at s 1 0)) :to-be-falsy)
      (expect (logbitp 0 (attrs-at s 1 0)))))

  (it-each ((38 nerimux/terminal/types:screen-cur-fg 200 "256-color fg=200")
            (48 nerimux/terminal/types:screen-cur-bg  42 "256-color bg=42"))
      "sgr-256color-apply-sgr: ~*~*~*~A"
      (code accessor n desc)
    (declare (ignore desc))
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s (list code 5 n))
      (expect (= n (funcall accessor s)))))

  (it-each (((38 2 255 128 0) nerimux/terminal/types:screen-cur-fg
             #.(logior #x1000000 (ash 255 16) (ash 128 8) 0) "truecolor fg 255;128;0")
            ((48 2 0 128 255) nerimux/terminal/types:screen-cur-bg
             #.(logior #x1000000 (ash 0 16) (ash 128 8) 255) "truecolor bg 0;128;255"))
      "sgr-truecolor-apply-sgr: ~*~*~*~A"
      (params accessor expected desc)
    (declare (ignore desc))
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s params)
      (expect (= expected (funcall accessor s)))))

  (it-each (("[38;5;200mX" fg-at 200 "256-color fg=200 via ESC[38;5;200m")
            ("[48;5;42mX"  bg-at  42 "256-color bg=42  via ESC[48;5;42m"))
      "sgr-256color-emulator: ~*~*~*~A"
      (seq cell-fn n desc)
    (declare (ignore desc))
    (with-screen (s 10 2)
      (feed s (esc seq))
      (expect (= n (funcall cell-fn s 0 0)))))

  (it "sgr-truecolor-black"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(38 2 0 0 0))
      (expect (= #x1000000 (nerimux/terminal/types:screen-cur-fg s)))))


  (it "sgr-colon-group-direct-truecolor"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '((38 2 255 128 0)))
      (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0)
             (nerimux/terminal/types:screen-cur-fg s)))))

  (it "sgr-colon-truecolor-fg-via-emulator"
    (with-screen (s 10 2)
      (feed s (esc "[38:2:255:128:0mX"))
      (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0) (fg-at s 0 0)))))

  (it "sgr-colon-truecolor-empty-colorspace"
    (with-screen (s 10 2)
      (feed s (esc "[38:2::255:128:0mX"))
      (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0) (fg-at s 0 0)))))

  (it "sgr-colon-truecolor-explicit-colorspace"
    (with-screen (s 10 2)
      (feed s (esc "[38:2:1:255:128:0mX"))
      (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0) (fg-at s 0 0)))))

  (it "sgr-colon-256color-via-emulator"
    (with-screen (s 10 2)
      (feed s (esc "[38:5:200mX"))
      (expect (= 200 (fg-at s 0 0)))))

  (it "sgr-colon-truecolor-bg-via-emulator"
    (with-screen (s 10 2)
      (feed s (esc "[48:2:0:128:255mX"))
      (expect (= (logior #x1000000 (ash 0 16) (ash 128 8) 255) (bg-at s 0 0)))))

  (it "sgr-colon-mixed-with-semicolon-params"
    (with-screen (s 10 2)
      (feed s (esc "[1;38:2:255:0:0mX"))
      (expect (= (logior #x1000000 (ash 255 16)) (fg-at s 0 0)))
      (expect (logbitp 0 (attrs-at s 0 0)) :to-be-truthy)))

  (it "sgr-colon-undercurl-applies-underline"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(4))
      (let ((plain-underline (nerimux/terminal/types:screen-cur-attrs s)))
        (nerimux/terminal/sgr:apply-sgr s '(0))           ; reset pen
        (nerimux/terminal/sgr:apply-sgr s '((4 3)))       ; undercurl colon group
        (expect (= plain-underline (nerimux/terminal/types:screen-cur-attrs s))))))


  (it-each ((#.nerimux/terminal/types:+default-color+ #.nerimux/terminal/types:+default-color+ 0 0
             "0"          "default pen")
            (1 #.nerimux/terminal/types:+default-color+ 1 0  "0;1;31"       "bold red fg (default bg)")
            (#.(logior #x1000000 (ash 255 16) (ash 128 8) 0) #.nerimux/terminal/types:+default-color+ 0 0
             "0;38;2;255;128;0"        "truecolor fg (default bg)")
            (#.nerimux/terminal/types:+default-color+ 12 0 0 "0;104"        "bright bg 12 (default fg)"))
      "pen-to-sgr-params: ~*~*~*~*~*~A"
      (fg bg attrs unicode expected desc)
    (declare (ignore desc))
    (expect (string= expected
                 (nerimux/terminal/sgr:%pen-to-sgr-params fg bg attrs unicode))))


  (it-each ((#.nerimux/terminal/types:+attr2-double-underline+
             "0;21" "double-underline bit alone -> ;21")
            (#.nerimux/terminal/types:+attr2-overline+
             "0;53" "overline bit alone -> ;53")
            (#.(logior nerimux/terminal/types:+attr2-double-underline+
                       nerimux/terminal/types:+attr2-overline+)
             "0;21;53" "both bits -> ;21;53 in declaration order"))
      "pen-to-sgr-params-attrs2: ~*~*~A"
      (attrs2 expected desc)
    (declare (ignore desc))
    (expect (string= expected
                 (nerimux/terminal/sgr:%pen-to-sgr-params
                  nerimux/terminal/types:+default-color+
                  nerimux/terminal/types:+default-color+
                  0 attrs2))))

  (it-each ((#.nerimux/terminal/types:+default-color+ nil ";39")
            (#.nerimux/terminal/types:+default-color+ t ";49")
            (1 nil ";31")
            (2 t ";42")
            (8 nil ";90")
            (15 t ";107")
            (16 nil ";38;5;16")
            (255 t ";48;5;255")
            (#.(logior #x1000000 (ash 255 16) (ash 0 8) 128)
             nil ";38;2;255;0;128")
            (#.(logior #x1000000 (ash 0 16) (ash 128 8) 255)
             t ";48;2;0;128;255"))
      "emit-sgr-color ~A background ~A -> ~A"
      (color background-p expected)
    (let ((out (with-output-to-string (s)
                  (funcall (symbol-function 'nerimux/terminal/sgr::%emit-sgr-color)
                           s color background-p))))
      (expect (string= expected out))))

  (it-each ((#.nerimux/terminal/types:+attr-bold+  ";1")
            (#.nerimux/terminal/types:+attr-dim+  ";2")
            (#.nerimux/terminal/types:+attr-italic+  ";3")
            (#.nerimux/terminal/types:+attr-underline+  ";4")
            (#.nerimux/terminal/types:+attr-blink+  ";5")
            (#.nerimux/terminal/types:+attr-reverse+  ";7")
            (#.nerimux/terminal/types:+attr-conceal+  ";8")
            (#.nerimux/terminal/types:+attr-strikethrough+  ";9"))
      "pen-to-sgr-params-attrs ~A -> ~A"
      (attrs expected)
    (expect (string= (concatenate 'string "0" expected)
                     (nerimux/terminal/sgr:%pen-to-sgr-params
                      nerimux/terminal/types:+default-color+
                      nerimux/terminal/types:+default-color+
                      attrs 0))))

  (it "sgr-reset-clears-new-attrs"
    (with-screen (s 10 2)
      (feed s (esc "[3;8;9mX"))    ; italic + conceal + strikethrough on
      (feed s (esc "[0mY"))        ; SGR reset
      (check-cell s 1 0 :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)))

  (it "sgr-22-does-not-clear-italic"
    (with-screen (s 10 2)
      (feed s (esc "[1;2;3mX"))    ; bold + dim + italic on
      (feed s (esc "[22mY"))       ; bold + dim off
      (expect (logbitp 5 (attrs-at s 1 0))))))

(in-package #:nerimux/test/terminal)

(describe "terminal-suite/direct-action-sgr"

  (it "apply-sgr-directly-updates-screen-attributes"
    (with-screen (s 10 5)
      (nerimux/terminal/sgr:apply-sgr s '(31))
      (expect (= 1 (nerimux/terminal/types:screen-cur-fg s)))
      (nerimux/terminal/sgr:apply-sgr s '(0))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (nerimux/terminal/sgr:apply-sgr s '(42))      ; bg green
      (nerimux/terminal/sgr:apply-sgr s nil)         ; empty = reset
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s)))))

  (it "apply-sgr-39-sets-default-sentinel"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(31))   ; red first
      (nerimux/terminal/sgr:apply-sgr s '(39))   ; default fg
      (expect (= nerimux/terminal/types:+default-color+
             (nerimux/terminal/types:screen-cur-fg s)))))

  (it "apply-sgr-49-sets-default-sentinel"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(42))   ; green bg first
      (nerimux/terminal/sgr:apply-sgr s '(49))   ; default bg
      (expect (= nerimux/terminal/types:+default-color+
             (nerimux/terminal/types:screen-cur-bg s)))))

  (it "sgr-reset-sgr-pen-helper"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(31 42 1))   ; fg=1, bg=2, bold
      (nerimux/terminal/types:reset-sgr-pen s)
      (check-sgr-state s :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)))

  (it "sgr-attr-on-helper"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::attr-on s nerimux/terminal/types:+attr-bold+)
      (nerimux/terminal/sgr::attr-on s nerimux/terminal/types:+attr-underline+)
      (expect (logbitp 0 (nerimux/terminal/types:screen-cur-attrs s)))
      (expect (logbitp 3 (nerimux/terminal/types:screen-cur-attrs s)))))

  (it "sgr-attr-off-helper"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::attr-on s nerimux/terminal/types:+attr-bold+)
      (nerimux/terminal/sgr::attr-on s nerimux/terminal/types:+attr-dim+)
      (nerimux/terminal/sgr::attr-off s nerimux/terminal/types:+attr-dim+)
      (expect (logbitp 0 (nerimux/terminal/types:screen-cur-attrs s)))
      (expect (logbitp 1 (nerimux/terminal/types:screen-cur-attrs s)) :to-be-falsy))))

(describe "terminal-suite/sgr-extended"

  (it "sgr-21-double-underline"
    (with-screen (s 10 2)
      (feed s (esc "[21mX"))
      (expect (not (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                              nerimux/terminal/types:+attr2-double-underline+))))))

  (it "sgr-21-double-underline-cleared-by-24"
    (with-screen (s 10 2)
      (feed s (esc "[4;21mX"))   ; underline + double-underline on
      (feed s (esc "[24mY"))     ; underline off
      (expect (logbitp 3 (nerimux/terminal/types:screen-cur-attrs s)) :to-be-falsy)
      (expect (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                         nerimux/terminal/types:+attr2-double-underline+)))))

  (it "sgr-overline-on-and-off"
    (with-screen (s 10 2)
      (feed s (esc "[53mX"))
      (expect (not (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                              nerimux/terminal/types:+attr2-overline+))))
      (feed s (esc "[55mY"))
      (expect (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                         nerimux/terminal/types:+attr2-overline+)))))

  (it "sgr-underline-color-set-and-reset"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(58 5 42))
      (expect (= 42 (nerimux/terminal/types:screen-cur-ul-color s)))
      (nerimux/terminal/sgr:apply-sgr s '(59))
      (expect (= 0 (nerimux/terminal/types:screen-cur-ul-color s))))))

(describe "terminal-suite/sgr"

  (it "sgr-black-fg-and-bg-table"
    (dolist (row (list (list "[30mX" #'fg-at "SGR 30 must set fg to 0 (black)")
                       (list "[40mX" #'bg-at "SGR 40 must set bg to 0 (black)")))
      (destructuring-bind (seq accessor desc) row
        (declare (ignore desc))
        (with-screen (s 10 2)
          (feed s (esc seq))
          (expect (= 0 (funcall accessor s 0 0)))))))

  (it "sgr-rapid-blink-6-sets-blink-bit"
    (with-screen (s 10 2)
      (feed s (esc "[6mB"))
      (expect (logbitp 4 (attrs-at s 0 0)))))

  (it "sgr-blink-off-25"
    (with-screen (s 10 2)
      (feed s (esc "[5mB"))   ; blink on
      (feed s (esc "[25mX"))  ; blink off
      (expect (logbitp 4 (attrs-at s 1 0)) :to-be-falsy)))

  (it "sgr-reverse-off-27"
    (with-screen (s 10 2)
      (feed s (esc "[7mR"))   ; reverse on
      (feed s (esc "[27mX"))  ; reverse off
      (expect (zerop (logand (attrs-at s 1 0) #b100)))))

  (it "sgr-framed-encircled-accepted-silently-table"
    (dolist (row '((51 "SGR 51 (framed)")
                   (52 "SGR 52 (encircled)")))
      (destructuring-bind (code desc) row
        (declare (ignore desc))
        (with-screen (s 10 2)
          (finishes (feed s (esc "[~DmX" code)))
          (expect (zerop (logand (attrs-at s 0 0) #b1111111)))))))

  (it "sgr-bright-background-table"
    (loop for code from 100 to 107
          for expected-bg from 8 to 15
          do (with-screen (s 10 2)
               (feed s (esc "[~DmX" code))
               (expect (= expected-bg (bg-at s 0 0)))))))

(describe "terminal-suite/direct-action-sgr"

  (it "dispatch-sgr-code-directly-table"
    (dolist (row (list (list 31 1 #'nerimux/terminal/types:screen-cur-fg "31 → cur-fg=1 (red)")
                       (list 42 2 #'nerimux/terminal/types:screen-cur-bg "42 → cur-bg=2 (green)")))
      (destructuring-bind (code expected accessor desc) row
        (declare (ignore desc))
        (with-screen (s 10 2)
          (nerimux/terminal/sgr:%dispatch-sgr-code s code)
          (expect (= expected (funcall accessor s)))))))

  (it "dispatch-sgr-code-unknown-is-noop"
    (with-screen (s 10 2)
      (finishes (nerimux/terminal/sgr:%dispatch-sgr-code s 999))
      (check-sgr-state s :fg nerimux/terminal/types:+default-color+ :bg nerimux/terminal/types:+default-color+ :attrs 0)))

  (it "attr2-on-and-off-helpers"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::attr2-on s nerimux/terminal/types:+attr2-overline+)
      (nerimux/terminal/sgr::attr2-on s nerimux/terminal/types:+attr2-double-underline+)
      (expect (not (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                              nerimux/terminal/types:+attr2-overline+))))
      (expect (not (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                              nerimux/terminal/types:+attr2-double-underline+))))
      (nerimux/terminal/sgr::attr2-off s nerimux/terminal/types:+attr2-overline+)
      (expect (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                         nerimux/terminal/types:+attr2-overline+)))
      (expect (not (zerop (logand (nerimux/terminal/types:screen-cur-attrs2 s)
                              nerimux/terminal/types:+attr2-double-underline+)))))))

(describe "terminal-suite/sgr-extended"

  (it "sgr-truecolor-underline-color"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr:apply-sgr s '(58 2 255 0 128))
      (let ((expected (logior #x1000000 (ash 255 16) (ash 0 8) 128)))
        (expect (= expected (nerimux/terminal/types:screen-cur-ul-color s)))))))

(describe "terminal-suite/direct-action-sgr"

  (it "define-sgr-rules-macro-is-defined"
    (expect (macro-function 'nerimux/terminal/sgr::define-sgr-rules)))

  (it "dispatch-sgr-code-has-docstring"
    (let ((doc (documentation 'nerimux/terminal/sgr:%dispatch-sgr-code 'function)))
      (expect (and (stringp doc) (plusp (length doc))))))


  (it "consume-256-color-param-sets-fg-and-advances"
    (with-screen (s 10 2)
      (let* ((parameter-tail '(38 5 42 99))
             (tail (nerimux/terminal/sgr::%consume-256-color-param
                    s #'(setf nerimux/terminal/types:screen-cur-fg) parameter-tail)))
        (expect (= 42 (nerimux/terminal/types:screen-cur-fg s)))
        (expect (equal '(99) tail)))))

  (it "consume-256-color-param-clamps-to-255"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::%consume-256-color-param
       s #'(setf nerimux/terminal/types:screen-cur-fg) '(38 5 300))
      (expect (= 255 (nerimux/terminal/types:screen-cur-fg s)))))


  (it "encode-truecolor-rgb-clamps-and-encodes"
    (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0)
           (nerimux/terminal/sgr::%encode-truecolor-rgb 255 128 0)))
    (expect (= (logior #x1000000 (ash 255 16) (ash 0 8) 255)
           (nerimux/terminal/sgr::%encode-truecolor-rgb 300 -5 999)))
    (expect (= #x1000000 (nerimux/terminal/sgr::%encode-truecolor-rgb nil nil nil))))

  (it "sgr-inline-helpers-are-callable-through-function-cells"
    (with-screen (s 10 2)
      (funcall (symbol-function 'nerimux/terminal/sgr::attr-on)
               s nerimux/terminal/types:+attr-bold+)
      (funcall (symbol-function 'nerimux/terminal/sgr::attr-off)
               s nerimux/terminal/types:+attr-bold+)
      (funcall (symbol-function 'nerimux/terminal/sgr::attr2-on)
               s nerimux/terminal/types:+attr2-overline+)
      (funcall (symbol-function 'nerimux/terminal/sgr::attr2-off)
               s nerimux/terminal/types:+attr2-overline+)
      (let ((encoded
              (funcall (symbol-function 'nerimux/terminal/sgr::%encode-truecolor-rgb)
                       1 2 3)))
        (expect (= #x1010203 encoded)))
      (let ((tail
              (funcall (symbol-function 'nerimux/terminal/sgr::%set-truecolor)
                       s #'(setf nerimux/terminal/types:screen-cur-fg)
                       '(38 2 1 2 3 99))))
        (expect (= #x1010203 (nerimux/terminal/types:screen-cur-fg s)))
        (expect (equal '(99) tail)))
      (let ((tail
              (funcall (symbol-function 'nerimux/terminal/sgr::%consume-256-color-param)
                       s #'(setf nerimux/terminal/types:screen-cur-bg)
                       '(48 5 42 99))))
        (expect (= 42 (nerimux/terminal/types:screen-cur-bg s)))
        (expect (equal '(99) tail)))))

  (it "apply-sgr-group-truecolor-sets-fg"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::%apply-sgr-group
       s (list 38 2 255 128 0))
      (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0)
             (nerimux/terminal/types:screen-cur-fg s)))))

  (it "apply-sgr-group-truecolor-skips-colourspace-field"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::%apply-sgr-group
       s (list 38 2 1 255 128 0))
      (expect (= (logior #x1000000 (ash 255 16) (ash 128 8) 0)
             (nerimux/terminal/types:screen-cur-fg s)))))

  (it "apply-sgr-group-256color-sets-bg"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::%apply-sgr-group s (list 48 5 200))
      (expect (= 200 (nerimux/terminal/types:screen-cur-bg s)))))

  (it "apply-sgr-group-plain-code-fallback"
    (with-screen (s 10 2)
      (nerimux/terminal/sgr::%apply-sgr-group s (list 4 3))
      (expect (logbitp 3 (nerimux/terminal/types:screen-cur-attrs s)))))

  (it "apply-sgr-color-arm-256color-advances-tail"
    (with-screen (s 10 2)
      (let ((tail (nerimux/terminal/sgr::%apply-sgr-color-arm s '(38 5 200 1))))
        (expect (= 200 (nerimux/terminal/types:screen-cur-fg s)))
        (expect (equal '(1) tail)))))

  (it "apply-sgr-color-arm-truecolor-advances-tail"
    (with-screen (s 10 2)
      (let ((tail (nerimux/terminal/sgr::%apply-sgr-color-arm
                   s '(48 2 0 128 255 7))))
        (expect (= (logior #x1000000 (ash 0 16) (ash 128 8) 255)
               (nerimux/terminal/types:screen-cur-bg s)))
        (expect (equal '(7) tail)))))

  (it "apply-sgr-color-arm-malformed-falls-back-to-plain-code"
    (with-screen (s 10 2)
      (let ((tail (nerimux/terminal/sgr::%apply-sgr-color-arm s '(38))))
        (expect (equal '() tail))))))

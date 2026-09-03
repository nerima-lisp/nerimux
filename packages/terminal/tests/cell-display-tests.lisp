(in-package #:nerimux/test/terminal)

(describe "terminal-suite/dec-graphics"

  (it "dec-graphics-table-macro-is-defined"
    (expect (macro-function 'nerimux/terminal/actions::define-dec-graphics-table)))

  (it "dec-graphics-remaps-box-drawing-chars"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-charset s) :dec-graphics)
      (nerimux/terminal/actions:write-char-at-cursor s #\j)
      (expect (char= #\┘ (char-at s 0 0)))
      (nerimux/terminal/actions:write-char-at-cursor s #\q)
      (expect (char= #\─ (char-at s 1 0)))
      (nerimux/terminal/actions:write-char-at-cursor s #\x)
      (expect (char= #\│ (char-at s 2 0)))))

  (it "dec-graphics-unmapped-char-passes-through"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-charset s) :dec-graphics)
      (nerimux/terminal/actions:write-char-at-cursor s #\A)
      (expect (char= #\A (char-at s 0 0)))))

  (it "remap-charset-char-ascii-mode-returns-unchanged"
    (with-screen (s 10 5)
      (expect (char= #\j
                     (nerimux/terminal/actions::%remap-charset-char s #\j)))))

  (it "remap-charset-char-dec-graphics-remaps-j"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-charset s) :dec-graphics)
      (expect (char= #\┘
                     (nerimux/terminal/actions::%remap-charset-char s #\j))))))

(describe "terminal-suite/bce-suite"

  (it "ed-clears-to-current-background"
    (with-screen (s 6 3)
      (feed s (esc "[44m"))          ; SGR 44 → background colour 4
      (feed s (esc "[2J"))           ; ED 2 → erase whole display
      (expect (= 4 (bg-at s 0 0)))
      (expect (= 4 (bg-at s 5 2)))
      (expect (char= #\Space (char-at s 0 0)))))

  (it "el-clears-to-current-background"
    (with-screen (s 6 3)
      (feed s (esc "[41m"))          ; background colour 1
      (feed s (esc "[K"))            ; EL 0 → cursor to end of line
      (expect (= 1 (bg-at s 0 0)))))

  (it "erase-without-background-is-default"
    (with-screen (s 6 3)
      (feed s "abc")
      (feed s (esc "[2J"))
      (expect (= nerimux/terminal/types:+default-color+ (bg-at s 0 0)))))

  (it "bce-resets-foreground-and-attrs"
    (with-screen (s 6 3)
      (feed s (esc "[1;31;44m"))     ; bold, fg red, bg blue
      (feed s (esc "[2J"))
      (expect (= 4 (bg-at s 0 0)))
      (expect (= nerimux/terminal/types:+default-color+ (fg-at s 0 0)))
      (expect (= 0 (attrs-at s 0 0))))))

(describe "terminal-suite/cross-file-constants"

  (it "true-color-flag-is-bit-24"
    (expect (= #x1000000 nerimux/terminal/types:+true-color-flag+)))

  (it "true-color-flag-does-not-overlap-palette-range"
    (expect (> nerimux/terminal/types:+true-color-flag+ 255))
    (expect (> nerimux/terminal/types:+true-color-flag+ nerimux/terminal/types:+default-color+)))

  (it "default-color-sentinel-is-256"
    (expect (= 256 nerimux/terminal/types:+default-color+)))

  (it "title-stack-max-depth-is-8"
    (expect (= 8 nerimux/terminal/types:+title-stack-max-depth+)))

  (it "osc-default-fg-is-white"
    (expect (= #xFFFFFF nerimux/terminal/types:+osc-default-fg+)))

  (it "osc-default-bg-is-black"
    (expect (= #x000000 nerimux/terminal/types:+osc-default-bg+)))

  (it "default-screen-width-is-80"
    (expect (= 80 nerimux/terminal/types:+default-screen-width+)))

  (it "default-screen-height-is-24"
    (expect (= 24 nerimux/terminal/types:+default-screen-height+)))

  (it "constants-table"
    (check-table (list (list nerimux/terminal/types:+true-color-flag+          #x1000000 "+true-color-flag+ = #x1000000")
                       (list nerimux/terminal/types:+default-color+            256        "+default-color+ = 256")
                       (list nerimux/terminal/types:+title-stack-max-depth+    8          "+title-stack-max-depth+ = 8")
                       (list nerimux/terminal/types:+osc-default-fg+           #xFFFFFF   "+osc-default-fg+ = #xFFFFFF")
                       (list nerimux/terminal/types:+osc-default-bg+           #x000000   "+osc-default-bg+ = #x000000")
                       (list nerimux/terminal/types:+default-screen-width+     80         "+default-screen-width+ = 80")
                       (list nerimux/terminal/types:+default-screen-height+    24         "+default-screen-height+ = 24")
                       (list nerimux/terminal/types:+unicode-replacement-char+ #xFFFD     "+unicode-replacement-char+ = #xFFFD"))
                 :test #'equal))

  (it "unicode-replacement-char-constant-is-fffd"
    (expect (= #xFFFD nerimux/terminal/types:+unicode-replacement-char+)))

  (it "safe-code-char-uses-replacement-char-for-invalid"
    (let ((result (nerimux/terminal/types:safe-code-char (+ char-code-limit 999))))
      (expect (= nerimux/terminal/types:+unicode-replacement-char+ (char-code result)))))

  (it "cell-helper-boundaries"
    (check-table (list (list (nerimux/terminal/types::clamp -1 0 10) 0 "clamp low")
                       (list (nerimux/terminal/types::clamp 5 0 10) 5 "clamp middle")
                       (list (nerimux/terminal/types::clamp 11 0 10) 10 "clamp high")
                       (list (nerimux/terminal/types::surrogate-code-point-p #xD7FF) nil "before surrogate block")
                       (list (nerimux/terminal/types::surrogate-code-point-p #xD800) t "surrogate start")
                       (list (nerimux/terminal/types::surrogate-code-point-p #xDFFF) t "surrogate end")
                       (list (nerimux/terminal/types::surrogate-code-point-p #xE000) nil "after surrogate block")
                       (list (char-code (nerimux/terminal/types:safe-code-char #x41)) #x41 "valid code point")
                       (list (char-code (nerimux/terminal/types:safe-code-char #xD800)) #xFFFD "surrogate replacement"))
                 :test #'equal))

  (it "cell-width-table"
    (check-table (list (list (nerimux/terminal/types::char-width #\A) 1 "ASCII")
                       (list (nerimux/terminal/types::char-width (code-char #x301)) 0 "combining mark")
                       (list (nerimux/terminal/types::char-width (code-char #x231A)) 2 "wide symbol"))
                 :test #'equal))

  (it "blank-cell-has-default-slots"
    (let ((c (nerimux/terminal/types:blank-cell)))
      (expect (char= #\Space (nerimux/terminal/types:cell-char c)))
      (expect (= nerimux/terminal/types:+default-color+
                 (nerimux/terminal/types:cell-fg c)))
      (expect (= nerimux/terminal/types:+default-color+
                 (nerimux/terminal/types:cell-bg c)))
      (expect (zerop (nerimux/terminal/types:cell-attrs c)))
      (expect (zerop (nerimux/terminal/types:cell-attrs2 c)))
      (expect (zerop (nerimux/terminal/types:cell-ul-color c)))
      (expect (null (nerimux/terminal/types:cell-combining c)))
      (expect (= 1 (nerimux/terminal/types:cell-width c))))))

(describe "terminal-suite/cell-hyperlink-suite"

  (it "make-cell-hyperlink-defaults-nil"
    (let ((c (nerimux/terminal/types:make-cell)))
      (expect (null (nerimux/terminal/types:cell-hyperlink c)))))

  (it "make-cell-hyperlink-can-be-set"
    (let ((c (nerimux/terminal/types:make-cell
              :char #\A :hyperlink "https://example.com")))
      (expect (string= "https://example.com"
                       (nerimux/terminal/types:cell-hyperlink c)))))

  (it "make-cell-hyperlink-empty-string"
    (let ((c (nerimux/terminal/types:make-cell :hyperlink "")))
      (expect (stringp (nerimux/terminal/types:cell-hyperlink c)))
      (expect (string= "" (nerimux/terminal/types:cell-hyperlink c)))))

  (it "blank-cell-hyperlink-is-nil"
    (let ((c (nerimux/terminal/types:blank-cell)))
      (expect (null (nerimux/terminal/types:cell-hyperlink c))))))

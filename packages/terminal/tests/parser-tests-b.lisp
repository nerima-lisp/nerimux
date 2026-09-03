(in-package #:nerimux/test/terminal)

(describe "terminal-suite/combining-chars"

  (it "combining-char-predicate-ranges"
    (expect (nerimux/terminal/actions:combining-char-p (code-char #x0300)) :to-be-truthy)
    (expect (nerimux/terminal/actions:combining-char-p (code-char #x036F)) :to-be-truthy)
    (expect (nerimux/terminal/actions:combining-char-p #\a) :to-be-falsy)
    (expect (nerimux/terminal/actions:combining-char-p #\Space) :to-be-falsy))

  (it "combining-char-appended-to-cell"
    (when (< #x0301 char-code-limit)   ; U+0301 = combining acute accent
      (with-screen (s 20 5)
        (feed s "e")                   ; base character 'e' at (0,0)
        (check-cursor s 1 0)
        (screen-process-bytes s (make-array 2 :element-type '(unsigned-byte 8)
                                              :initial-contents '(#xCC #x81)))
        (check-cursor s 1 0)
        (let ((cell (screen-cell s 0 0)))
          (expect (member (code-char #x0301) (nerimux/terminal/types:cell-combining cell))))))))

(defmacro check-dec-graphics (char expected-char description)
  "Assert that %dec-graphics-char maps CHAR to EXPECTED-CHAR with DESCRIPTION."
  (declare (ignore description))
  `(expect
    (char= ,expected-char (nerimux/terminal/actions::%dec-graphics-char ,char))))

(describe "terminal-suite/acs-line-drawing"

  (it "acs-charset-switch"
    (with-screen (s 20 5)
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))
      (feed s (format nil "~C(0" #\Escape))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))
      (feed s (format nil "~C(B" #\Escape))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "acs-line-drawing-maps-chars-table"
    (dolist (row '(("q" #\─ "DEC graphics 'q' → ─ (U+2500)")
                   ("x" #\│ "DEC graphics 'x' → │ (U+2502)")))
      (destructuring-bind (input expected desc) row
        (declare (ignore desc))
        (with-screen (s 20 5)
          (feed s (format nil "~C(0" #\Escape))
          (feed s input)
          (expect (char= expected (char-at s 0 0)))))))

  (it "acs-ascii-mode-unaffected"
    (with-screen (s 20 5)
      (feed s (format nil "~C(B" #\Escape))
      (feed s "q")
      (expect (char= #\q (char-at s 0 0)))))

  (it "dec-graphics-corner-characters"
    (check-dec-graphics #\j #\┘ "j must map to lower-right corner (┘)")
    (check-dec-graphics #\k #\┐ "k must map to upper-right corner (┐)")
    (check-dec-graphics #\l #\┌ "l must map to upper-left corner (┌)")
    (check-dec-graphics #\m #\└ "m must map to lower-left corner (└)")
    (check-dec-graphics #\n #\┼ "n must map to crossing (┼)")
    (check-dec-graphics #\t #\├ "t must map to left tee (├)")
    (check-dec-graphics #\u #\┤ "u must map to right tee (┤)")
    (check-dec-graphics #\v #\┴ "v must map to bottom tee (┴)")
    (check-dec-graphics #\w #\┬ "w must map to top tee (┬)"))

  (it "dec-graphics-special-characters"
    (check-dec-graphics #\a #\▒ "a must map to checkerboard (▒)")
    (check-dec-graphics #\` #\◆ "` must map to diamond (◆)")
    (check-dec-graphics #\f #\° "f must map to degree symbol (°)")
    (check-dec-graphics #\g #\± "g must map to plus-minus (±)"))

  (it "dec-graphics-scan-lines"
    (check-dec-graphics #\o #\⎺ "o must map to scan line 1 (top)")
    (check-dec-graphics #\p #\⎻ "p must map to scan line 3")
    (check-dec-graphics #\q #\─ "q must map to scan line 5 (horizontal line)")
    (check-dec-graphics #\r #\⎼ "r must map to scan line 7")
    (check-dec-graphics #\s #\⎽ "s must map to scan line 9 (bottom)"))

  (it "dec-graphics-math-and-symbol-characters"
    (check-dec-graphics #\y #\≤ "y must map to less-than-or-equal (≤)")
    (check-dec-graphics #\z #\≥ "z must map to greater-than-or-equal (≥)")
    (check-dec-graphics #\{ #\π "{ must map to pi (π)")
    (check-dec-graphics #\| #\≠ "| must map to not-equal (≠)")
    (check-dec-graphics #\} #\£ "} must map to UK pound sign (£)")
    (check-dec-graphics #\~ #\· "~ must map to centred dot (·)")
    (check-dec-graphics #\_ #\Space "_ must map to a blank"))

  (it "dec-graphics-unmapped-char-returned-unchanged"
    (check-dec-graphics #\5 #\5 "unmapped '5' must be returned unchanged")
    (check-dec-graphics #\A #\A "unmapped 'A' must be returned unchanged"))

  (it "dec-graphics-via-emulator-corner-chars"
    (with-screen (s 20 5)
      (feed s (format nil "~C(0" #\Escape))  ; switch to DEC graphics
      (feed s "jklm")
      (expect (char= #\┘ (char-at s 0 0)))
      (expect (char= #\┐ (char-at s 1 0)))
      (expect (char= #\┌ (char-at s 2 0)))
      (expect (char= #\└ (char-at s 3 0)))))

  (it "define-dec-graphics-table-macro-is-defined"
    (expect (macro-function 'nerimux/terminal/actions::define-dec-graphics-table))))

(defun %feed-dcs (s payload)
  "Feed a DCS sequence (ESC P PAYLOAD ST) to screen S via screen-process-bytes."
  (screen-process-bytes s
                        (cl-codec-kit:string-to-octets
                         (format nil "~CP~A~C\\" #\Escape payload #\Escape)
                         :encoding
                         :utf-8)))

(describe "terminal-suite/dcs-parsing"

  (it "dcs-consumed-silently"
    (with-screen (s 20 5)
      (feed s "a")
      (screen-process-bytes s
        (make-array 7 :element-type '(unsigned-byte 8)
                      :initial-contents (list #x1B #x50
                                             (char-code #\1)
                                             (char-code #\$)
                                             (char-code #\p)
                                             #x1B #x5C)))
      (feed s "b")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\b (char-at s 1 0)))))

  (it "dcs-parser-returns-ground-state-after-st"
    (with-screen (s 20 5)
      (screen-process-bytes s
        (make-array 9 :element-type '(unsigned-byte 8)
                      :initial-contents (list #x1B #x50
                                             (char-code #\H) (char-code #\e)
                                             (char-code #\l) (char-code #\l)
                                             (char-code #\o)
                                             #x1B #x5C)))
      (feed s "X")
      (expect (char= #\X (char-at s 0 0)))))


  (it "hex-decode-encode-roundtrip"
    (flet ((decode (s) (nerimux/terminal/parser::%hex-decode-string s))
           (encode (s) (nerimux/terminal/parser::%hex-encode-string s)))
      (dolist (c `(("Tc"   ,(lambda () (decode "5463"))   "5463 -> Tc")
                   ("5463" ,(lambda () (encode "Tc"))     "Tc -> 5463")
                   ("256"  ,(lambda () (decode "323536")) "323536 -> 256")
                   (nil    ,(lambda () (decode "5"))      "odd-length -> NIL")))
        (destructuring-bind (expected fn desc) c
          (declare (ignore desc))
          (expect (equal expected (funcall fn)))))))

  (it "xtgettcap-responses-table"
    (dolist (row (list (list "+q5463"         (format nil "~CP1+r5463~C\\"          #\Escape #\Escape) "Tc → DCS 1+r 5463")
                       (list "+q524742"        (format nil "~CP1+r524742~C\\"        #\Escape #\Escape) "RGB → DCS 1+r 524742")
                       (list "+q636f6c6f7273"  (format nil "~CP1+r636f6c6f7273=323536~C\\" #\Escape #\Escape) "colors → DCS 1+r with =323536")
                       (list "+q5878"          (format nil "~CP0+r5878~C\\"          #\Escape #\Escape) "unknown cap → DCS 0+r")))
      (destructuring-bind (dcs-input expected desc) row
        (declare (ignore desc))
        (with-screen (s 20 5)
          (%feed-dcs s dcs-input)
          (expect (string= expected (first (nerimux/terminal/types:screen-response-queue s))))))))


  (it "decrqss-sgr-reports-current-pen"
    (with-screen (s 20 5)
      (feed s (esc "[1;31m"))        ; bold red pen
      (%feed-dcs s "$qm")
      (expect (string= (format nil "~CP1$r0;1;31m~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "decrqss-scroll-region-reports-margins"
    (with-screen (s 20 5)
      (%feed-dcs s "$qr")
      (expect (string= (format nil "~CP1$r1;5r~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "decrqss-cursor-style-reports-shape"
    (with-screen (s 20 5)
      (feed s (esc "[3 q"))          ; DECSCUSR shape 3
      (%feed-dcs s "$q q")
      (expect (string= (format nil "~CP1$r3 q~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "decrqss-unknown-reports-invalid"
    (with-screen (s 20 5)
      (%feed-dcs s "$qx")
      (expect (string= (format nil "~CP0$r~C\\" #\Escape #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s)))))))

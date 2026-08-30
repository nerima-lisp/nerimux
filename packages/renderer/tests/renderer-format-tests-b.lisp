(in-package #:nerimux/test/renderer)

;;;; renderer-format tests — part B: render-cell-attrs all-attributes table,
;;;; attrs2 double-underline/overline, ul-color, move-to, %emit-sgr,
;;;; %center-coord.
;;;;
;;;; R2.4 deleted the tmux style-string parser (%dispatch-style-token,
;;;; %emit-style-attrs, parse-style-string, style-to-sgr,
;;;; %color-name-to-sgr-number, %border-color-sgr, %classify-color-name) —
;;;; see renderer-format-tests.lisp's header for the full list and why.

(describe "renderer-suite"

  ;; Table-driven test: each attribute bit produces the expected SGR code.
  (it-each ((1   ";1"  "bold")
            (2   ";2"  "dim")
            (4   ";7"  "reverse")
            (8   ";4"  "underline")
            (16  ";5"  "blink")
            (32  ";3"  "italic")
            (64  ";8"  "conceal")
            (128 ";9"  "strikethrough"))
      "render-cell-attrs-all-attributes: ~*~*~A"
      (attrs expected desc)
    (declare (ignore desc))
    (let ((out (cell-attrs-string 0 0 attrs)))
      (expect (search expected out))))

  ;;; ── attrs2: double-underline and overline ────────────────────────────────────

  ;; Each attrs2 bit alone emits the correct SGR code.
  (it-each ((1 ";21" "double-underline (attrs2 bit0) → ;21")
            (2 ";53" "overline (attrs2 bit1) → ;53"))
      "render-cell-attrs2-single-bit: ~*~*~A"
      (attrs2 expected desc)
    (declare (ignore desc))
    (let ((out (cell-attrs-string 0 0 0 attrs2)))
      (expect (search expected out))))

  ;; attrs2 with both bits set emits both ;21 and ;53.
  (it "render-cell-attrs2-double-underline-and-overline"
    (let ((out (cell-attrs-string 0 0 0 3)))    ; attrs2 bits 0+1
      (expect (search ";21" out))
      (expect (search ";53" out))))

  ;; attrs2 = 0 does not emit ;21 or ;53.
  (it "render-cell-attrs2-zero-emits-nothing-extra"
    (let ((out (cell-attrs-string 0 0 0 0)))
      (expect (not (search ";21" out)))
      (expect (not (search ";53" out)))))

  ;;; ── ul-color: underline colour (SGR 58) ─────────────────────────────────────

  ;; ul-color: 0 emits nothing; palette 200 emits ;58;5;200; truecolor emits ;58;2;255;0;128.
  (it "render-cell-attrs-ul-color-table"
    (dolist (row (list (list 0                                              nil             "ul-color=0 must not emit ;58")
                       (list 200                                            ";58;5;200"     "palette ul-color 200 must emit ;58;5;200")
                       (list (logior #x1000000 (ash 255 16) (ash 0 8) 128) ";58;2;255;0;128" "truecolor must emit ;58;2;255;0;128")))
      (destructuring-bind (ul-color expected-sub desc) row
        (declare (ignore desc))
        (let ((out (cell-attrs-string 0 0 0 0 ul-color)))
          (if expected-sub
              (expect (search expected-sub out))
              (expect (not (search ";58" out))))))))

  ;;; ── move-to additional positions ─────────────────────────────────────────────

  ;; move-to with large row and col values produces the correct 1-based sequence.
  (it "move-to-large-coordinates"
    (expect (string= (format nil "~C[100;200H" #\Escape)
                     (with-output-to-string (s)
                       (nerimux/renderer::move-to s 99 199)))))

  ;;; ── %center-coord (box centring) ─────────────────────────────────────────────

  ;; %center-coord returns floor((total-size)/2), clamped to 0 when size >= total.
  (it-each ((80 20 30 "80 wide, size 20 -> offset 30")
            (10 10  0 "size equals total -> offset 0")
            (10 20  0 "size larger than total -> clamped to 0")
            (81 40 20 "odd total centres via floor"))
      "center-coord: ~*~*~A"
      (total size expected desc)
    (declare (ignore desc))
    (expect (= expected (nerimux/renderer::%center-coord total size))))

  ;;; ── %emit-sgr (raw SGR code emission) ────────────────────────────────────────

  ;; %emit-sgr writes ESC[CODEm for an integer or string code.
  (it "emit-sgr-writes-escape-sequence-for-code"
    (expect (string= (format nil "~C[44m" #\Escape)
                     (with-output-to-string (s) (nerimux/renderer::%emit-sgr s 44))))
    (expect (string= (format nil "~C[44;97m" #\Escape)
                     (with-output-to-string (s) (nerimux/renderer::%emit-sgr s "44;97")))))

  ;; %emit-sgr with a NIL code writes nothing to the stream.
  (it "emit-sgr-nil-code-is-a-no-op"
    (expect (string= "" (with-output-to-string (s) (nerimux/renderer::%emit-sgr s nil))))))

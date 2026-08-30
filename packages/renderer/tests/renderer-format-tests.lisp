(in-package #:nerimux/test/renderer)

;;;; Escape-code format primitive tests.
;;;;
;;;; Covers: ANSI escape-code helpers in src/presentation/renderer/renderer-format.lisp:
;;;;   +esc+, move-to, define-cell-attr-renderer, cursor-invisible/visible, reset-attrs,
;;;;   set-cursor-shape, %emit-fg/%emit-bg, *color-downsample-fn*.
;;;;
;;;; R2.4 deleted the tmux style-string parser (parse-style-string,
;;;; %split-style-tokens, %dispatch-style-token, %emit-style-attrs,
;;;; %border-color-sgr, %color-name-to-sgr-number, %status-sgr-from-style,
;;;; %effective-status-style) along with the option system it existed to
;;;; read — see renderer-style.lisp and renderer-style-data.lisp.  Every
;;;; style this renderer emits is now a fixed SGR constant, so there is no
;;;; longer a runtime string to parse or classify.

(describe "renderer-suite"

  ;; ── Helper ──────────────────────────────────────────────────────────────────

  (defun cell-attrs-string (fg bg attrs &optional (attrs2 0) (ul-color 0))
    (with-output-to-string (s)
      (nerimux/renderer::render-cell-attrs s fg bg attrs attrs2 ul-color)))

  ;; ── move-to (1-based conversion) ────────────────────────────────────────────

  ;; move-to converts 0-based row/col arguments to 1-based ESC[row;colH sequences.
  (it "move-to-is-one-based"
    (expect (string= (format nil "~C[1;1H" #\Escape)
                     (with-output-to-string (s)
                       (nerimux/renderer::move-to s 0 0))))
    (expect (string= (format nil "~C[3;5H" #\Escape)
                     (with-output-to-string (s)
                       (nerimux/renderer::move-to s 2 4)))))

  ;; ── render-cell-attrs (SGR codes) ───────────────────────────────────────────

  ;; render-cell-attrs emits the correct SGR code for standard fg, bg, and bright fg.
  (it-each ((1 0 ";31")
            (0 2 ";42")
            (9 0 ";91"))
      "render-cell-attrs fg ~A bg ~A → ~A"
      (fg bg expected)
    (expect (search expected (cell-attrs-string fg bg 0))))

  ;; render-cell-attrs always wraps its SGR codes in a leading ESC[0 reset and a trailing m.
  (it "render-cell-attrs-frame"
    (let ((out (cell-attrs-string 1 2 1)))
      (expect (eql 0 (search (format nil "~C[0" #\Escape) out)))
      (expect (char= #\m (char out (1- (length out)))))))

  ;; fg/bg outside 0..15 emit no colour code — only the leading reset remains.
  (it "render-cell-attrs-default-color-omitted"
    (let ((out (cell-attrs-string -1 -1 0)))
      (expect (string= (format nil "~C[0m" #\Escape) out))))

  ;; ── cursor-invisible / cursor-visible ───────────────────────────────────────

  ;; cursor-invisible emits ESC[?25l; cursor-visible emits ESC[?25h.
  (it-each ((nerimux/renderer::cursor-invisible "?25l")
            (nerimux/renderer::cursor-visible   "?25h"))
      "~A → ESC[~A"
      (fn suffix)
    (let ((out (with-output-to-string (s) (funcall fn s))))
      (expect (string= (format nil "~C[~A" #\Escape suffix) out))))

  ;; ── reset-attrs ─────────────────────────────────────────────────────────────

  ;; reset-attrs writes ESC[0m to the stream.
  (it "reset-attrs-emits-sgr-zero-m"
    (let ((s (make-string-output-stream)))
      (nerimux/renderer::reset-attrs s)
      (expect (string= (format nil "~C[0m" #\Escape)
                       (get-output-stream-string s)))))

  ;; define-cell-attr-renderer is a defined macro.
  (it "define-cell-attr-renderer-macro-is-defined"
    (expect (macro-function 'nerimux/renderer::define-cell-attr-renderer)))

  ;; ── render-cell-attrs attribute-bit table ───────────────────────────────────
  ;;
  ;; All single-bit attribute flags: each row is (bit-value SGR-search-string label).

  ;; Each attrs bit-flag causes render-cell-attrs to include the correct SGR code.
  ;; Rows: (attrs-value expected-sgr-substring label).
  (it-each ((1   ";1")
            (2   ";2")
            (4   ";7")
            (8   ";4")
            (16  ";5")
            (32  ";3")
            (64  ";8")
            (128 ";9"))
      "render-cell-attrs attrs-bit ~A → ~A"
      (attrs sgr)
    (expect (search sgr (cell-attrs-string 0 0 attrs))))

  ;; ── Extended colour emit paths ───────────────────────────────────────────────

  ;; 256-color palette indices emit the correct extended SGR sequences.
  (it-each ((200 0   ";38;5;200")
            (0   42  ";48;5;42"))
      "render-cell-attrs 256-colour fg ~A bg ~A → ~A"
      (fg bg expected)
    (expect (search expected (cell-attrs-string fg bg 0))))

  ;; True-color values emit the correct 38;2;R;G;B / 48;2;R;G;B SGR sequences.
  (it "render-cell-attrs-truecolor-table"
    (dolist (c (list (list (logior #x1000000 (ash 255 16) (ash 128 8)   0) 0 ";38;2;255;128;0"   "truecolor fg → ;38;2;255;128;0")
                     (list 0 (logior #x1000000 (ash 0   16) (ash 128 8) 255) ";48;2;0;128;255"   "truecolor bg → ;48;2;0;128;255")))
      (destructuring-bind (fg bg expected desc) c
        (declare (ignore desc))
        (let ((out (cell-attrs-string fg bg 0)))
          (expect (search expected out))))))

  ;; ── set-cursor-shape ─────────────────────────────────────────────────────────

  ;; set-cursor-shape emits the DECSCUSR sequence ESC[N q for each shape number.
  (it-each ((2 "2 q")
            (1 "1 q"))
      "set-cursor-shape ~A → ESC[~A"
      (shape suffix)
    (let ((out (with-output-to-string (s) (nerimux/renderer::set-cursor-shape s shape))))
      (expect (search (format nil "~C[~A" #\Escape suffix) out))))

  ;; ── %emit-fg / %emit-bg palette boundaries ────────────────────────────────────

  ;; Verifies fg/bg SGR emission at standard-colour, bright, and 256-colour boundaries.
  ;; Each row is (fg bg expected-sgr-substring description).
  (it-each ((7   0   ";37")
            (0   0   ";40")
            (8   0   ";90")
            (15  0   ";97")
            (16  0   ";38;5;16")
            (255 0   ";38;5;255")
            (0   16  ";48;5;16")
            (0   255 ";48;5;255"))
      "emit fg ~A bg ~A → ~A"
      (fg bg expected)
    (expect (search expected (cell-attrs-string fg bg 0))))

  ;; ── %rgb-int-to-256 / %maybe-downsample-color / *color-downsample-fn* ───────
  ;;
  ;; Real tmux's -2 flag forces 256-colour output even when the caller sends
  ;; true-colour cell values; %apply-global-cli-invocation (main-startup.lisp)
  ;; wires that up by setting *color-downsample-fn* to #'%rgb-int-to-256, which
  ;; %emit-fg/%emit-bg (via %maybe-downsample-color) consult before classifying
  ;; a true-colour value. Reference downsample values below match cl-tty-kit's
  ;; own rgb-to-256 test table (tests/color-test.lisp).

  ;; %rgb-int-to-256 downsamples a packed true-colour int (bit 24 set) to the
  ;; correct xterm 256-palette index. Each case is (packed-int expected desc).
  (it-each ((#.(logior #x1000000 (ash 0   16) (ash 0   8) 0)   16  "black")
            (#.(logior #x1000000 (ash 255 16) (ash 255 8) 255) 231 "white")
            (#.(logior #x1000000 (ash 0   16) (ash 0   8) 255) 21  "blue")
            (#.(logior #x1000000 (ash 128 16) (ash 128 8) 128) 244 "grey"))
      "rgb-int-to-256: ~*~*~A"
      (n expected desc)
    (declare (ignore desc))
    (expect (= expected (nerimux/renderer:%rgb-int-to-256 n))))

  ;; %maybe-downsample-color returns N unchanged when *color-downsample-fn* is
  ;; NIL (the default), for both true-colour and non-true-colour N.
  (it "maybe-downsample-color-nil-fn-returns-unchanged"
    (let ((nerimux/renderer:*color-downsample-fn* nil))
      (expect (= 42 (nerimux/renderer::%maybe-downsample-color 42)))
      (expect (= (logior #x1000000 255)
                (nerimux/renderer::%maybe-downsample-color (logior #x1000000 255))))))

  ;; %maybe-downsample-color only applies *color-downsample-fn* to true-colour
  ;; values (bit 24 set); a non-true-colour N is returned unchanged even when
  ;; a downsample function is bound.
  (it "maybe-downsample-color-applies-fn-only-to-truecolor"
    (let ((nerimux/renderer:*color-downsample-fn* (lambda (n) (declare (ignore n)) 99)))
      (expect (= 99 (nerimux/renderer::%maybe-downsample-color (logior #x1000000 1))))
      (expect (= 5  (nerimux/renderer::%maybe-downsample-color 5)))))

  (it "maybe-downsample-color-function-object-covers-dispatch"
    (let ((nerimux/renderer:*color-downsample-fn* (lambda (n) (declare (ignore n)) 99))
          (fn (symbol-function 'nerimux/renderer::%maybe-downsample-color)))
      (expect (= 99 (funcall fn (logior #x1000000 1))))
      (expect (= 5 (funcall fn 5)))))

  (it-each ((0 "" "no underline colour")
            (16 ";58;5;16" "palette underline colour")
            (#.(logior #x1000000 (ash 255 16) (ash 0 8) 128)
             ";58;2;255;0;128"
             "true-colour underline colour"))
      "emit underline colour ~A → ~A"
      (n expected desc)
    (declare (ignore desc))
    (let ((out (with-output-to-string (s)
                  (funcall (symbol-function 'nerimux/renderer::%emit-ul-color)
                           s n))))
      (expect (string= expected out))))

  ;; End-to-end: with *color-downsample-fn* bound to #'%rgb-int-to-256 (as
  ;; %apply-global-cli-invocation wires it for -2), render-cell-attrs emits the
  ;; downsampled 256-colour SGR form (;38;5;N) instead of raw true-colour
  ;; (;38;2;R;G;B) for a true-colour fg value.
  (it "render-cell-attrs-downsamples-truecolor-fg-when-fn-bound"
    (let ((nerimux/renderer:*color-downsample-fn* #'nerimux/renderer:%rgb-int-to-256))
      (let ((out (cell-attrs-string (logior #x1000000 (ash 0 16) (ash 0 8) 255) 0 0)))
        (expect (search ";38;5;21" out))
        (expect (not (search ";38;2;" out))))))
  )

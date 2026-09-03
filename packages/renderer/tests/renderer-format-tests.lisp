(in-package #:nerimux/test/renderer)

(describe "renderer-suite"


  (defun cell-attrs-string (fg bg attrs &optional (attrs2 0) (ul-color 0))
    (with-output-to-string (s)
      (nerimux/renderer::render-cell-attrs s fg bg attrs attrs2 ul-color)))


  (it "move-to-is-one-based"
    (expect (string= (format nil "~C[1;1H" #\Escape)
                     (with-output-to-string (s)
                       (nerimux/renderer::move-to s 0 0))))
    (expect (string= (format nil "~C[3;5H" #\Escape)
                     (with-output-to-string (s)
                       (nerimux/renderer::move-to s 2 4)))))


  (it-each ((1 0 ";31")
            (0 2 ";42")
            (9 0 ";91"))
      "render-cell-attrs fg ~A bg ~A → ~A"
      (fg bg expected)
    (expect (search expected (cell-attrs-string fg bg 0))))

  (it "render-cell-attrs-frame"
    (let ((out (cell-attrs-string 1 2 1)))
      (expect (eql 0 (search (format nil "~C[0" #\Escape) out)))
      (expect (char= #\m (char out (1- (length out)))))))

  (it "render-cell-attrs-default-color-omitted"
    (let ((out (cell-attrs-string -1 -1 0)))
      (expect (string= (format nil "~C[0m" #\Escape) out))))


  (it-each ((nerimux/renderer::cursor-invisible "?25l")
            (nerimux/renderer::cursor-visible   "?25h"))
      "~A → ESC[~A"
      (fn suffix)
    (let ((out (with-output-to-string (s) (funcall fn s))))
      (expect (string= (format nil "~C[~A" #\Escape suffix) out))))


  (it "reset-attrs-emits-sgr-zero-m"
    (let ((s (make-string-output-stream)))
      (nerimux/renderer::reset-attrs s)
      (expect (string= (format nil "~C[0m" #\Escape)
                       (get-output-stream-string s)))))

  (it "define-cell-attr-renderer-macro-is-defined"
    (expect (macro-function 'nerimux/renderer::define-cell-attr-renderer)))


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


  (it-each ((200 0   ";38;5;200")
            (0   42  ";48;5;42"))
      "render-cell-attrs 256-colour fg ~A bg ~A → ~A"
      (fg bg expected)
    (expect (search expected (cell-attrs-string fg bg 0))))

  (it "render-cell-attrs-truecolor-table"
    (dolist (c (list (list (logior #x1000000 (ash 255 16) (ash 128 8)   0) 0 ";38;2;255;128;0"   "truecolor fg → ;38;2;255;128;0")
                     (list 0 (logior #x1000000 (ash 0   16) (ash 128 8) 255) ";48;2;0;128;255"   "truecolor bg → ;48;2;0;128;255")))
      (destructuring-bind (fg bg expected desc) c
        (declare (ignore desc))
        (let ((out (cell-attrs-string fg bg 0)))
          (expect (search expected out))))))


  (it-each ((2 "2 q")
            (1 "1 q"))
      "set-cursor-shape ~A → ESC[~A"
      (shape suffix)
    (let ((out (with-output-to-string (s) (nerimux/renderer::set-cursor-shape s shape))))
      (expect (search (format nil "~C[~A" #\Escape suffix) out))))


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


  (it-each ((#.(logior #x1000000 (ash 0   16) (ash 0   8) 0)   16  "black")
            (#.(logior #x1000000 (ash 255 16) (ash 255 8) 255) 231 "white")
            (#.(logior #x1000000 (ash 0   16) (ash 0   8) 255) 21  "blue")
            (#.(logior #x1000000 (ash 128 16) (ash 128 8) 128) 244 "grey"))
      "rgb-int-to-256: ~*~*~A"
      (n expected desc)
    (declare (ignore desc))
    (expect (= expected (nerimux/renderer:%rgb-int-to-256 n))))

  (it "maybe-downsample-color-nil-fn-returns-unchanged"
    (let ((nerimux/renderer:*color-downsample-fn* nil))
      (expect (= 42 (nerimux/renderer::%maybe-downsample-color 42)))
      (expect (= (logior #x1000000 255)
                (nerimux/renderer::%maybe-downsample-color (logior #x1000000 255))))))

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

  (it "render-cell-attrs-downsamples-truecolor-fg-when-fn-bound"
    (let ((nerimux/renderer:*color-downsample-fn* #'nerimux/renderer:%rgb-int-to-256))
      (let ((out (cell-attrs-string (logior #x1000000 (ash 0 16) (ash 0 8) 255) 0 0)))
        (expect (search ";38;5;21" out))
        (expect (not (search ";38;2;" out))))))
  )

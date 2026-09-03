(in-package #:nerimux/test/terminal)

(defmacro assert-all-cells-blank (screen)
  "Assert that every cell in SCREEN is a space with default fg/bg attributes.
   Expands to one EXPECT form per cell position."
  (let ((s (gensym "SCREEN")))
    `(let ((,s ,screen))
       (dotimes (y (screen-height ,s))
         (dotimes (x (screen-width ,s))
           (let ((c (screen-cell ,s x y)))
             (expect (char= #\Space (cell-char c)))
             (expect (= nerimux/terminal/types:+default-color+ (cell-fg c)))
             (expect (= nerimux/terminal/types:+default-color+ (cell-bg c)))))))))

(describe "terminal-suite/screen-construction"

  (it "make-screen-sets-width-and-height"
    (let ((s (make-screen 40 12)))
      (expect (= 40 (screen-width  s)))
      (expect (= 12 (screen-height s)))))

  (it "make-screen-cursor-starts-at-origin"
    (with-screen (s 20 10)
      (expect (= 0 (screen-cursor-x s)))
      (expect (= 0 (screen-cursor-y s)))))

  (it "make-screen-dirty-flag-is-true"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-truthy)))

  (it "make-screen-scroll-region-is-full-height"
    (with-screen (s 80 24)
      (expect (= 0  (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 23 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "make-screen-all-cells-are-blank"
    (with-screen (s 5 3)
      (assert-all-cells-blank s)))

  (it "make-screen-cursor-visible-defaults-true"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-cursor-visible s) :to-be-truthy)))

  (it "make-screen-copy-mode-defaults-false"
    (with-screen (s 10 5)
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (expect (= 0 (screen-copy-offset s)))))

  (it "make-screen-response-queue-starts-empty"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-response-queue s)))))

  (it "make-screen-saved-cursor-starts-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-saved-cursor s)))))

  (it "make-screen-scrollback-starts-empty"
    (with-screen (s 10 5)
      (expect (null (screen-scrollback s))))))

(describe "terminal-suite/screen-p-suite"

  (it "screen-p-returns-true-for-make-screen"
    (let ((s (make-screen 10 5)))
      (expect (nerimux/terminal/types:screen-p s) :to-be-truthy)))

  (it "screen-p-returns-false-for-non-screen"
    (expect (nerimux/terminal/types:screen-p 42) :to-be-falsy)
    (expect (nerimux/terminal/types:screen-p "hello") :to-be-falsy)
    (expect (nerimux/terminal/types:screen-p nil) :to-be-falsy)
    (expect (nerimux/terminal/types:screen-p (nerimux/terminal/types:make-cell)) :to-be-falsy)))

(describe "terminal-suite/make-screen-direct"

  (it "percent-make-screen-produces-screen-of-correct-dimensions"
    (let* ((w 15) (h 6)
           (cells (nerimux/terminal/types:%make-blank-cells (* w h)))
           (s (nerimux/terminal/types:%make-screen :width w :height h :cells cells
                                                    :scroll-bottom (1- h))))
      (expect (= w (screen-width  s)))
      (expect (= h (screen-height s)))
      (expect (nerimux/terminal/types:screen-p s)))))

(describe "terminal-suite/screen-cell-access"

  (it "screen-cell-read-returns-correct-cell"
    (with-screen (s 5 3)
      (feed s "A")             ; writes 'A' at (0,0), cursor advances to (1,0)
      (expect (char= #\A (cell-char (screen-cell s 0 0))))))

  (it "setf-screen-cell-stores-cell-at-position"
    (with-screen (s 5 3)
      (let ((new-cell (nerimux/terminal/types:make-cell :char #\Z :fg 3 :bg 1)))
        (setf (screen-cell s 2 1) new-cell)
        (let ((read-back (screen-cell s 2 1)))
          (expect (char= #\Z (cell-char read-back)))
          (expect (= 3 (cell-fg  read-back)))
          (expect (= 1 (cell-bg  read-back)))))))

  (it "screen-cell-bottom-right-is-accessible"
    (with-screen (s 10 8)
      (finishes (screen-cell s 9 7))))

  (it "screen-cell-write-read-table"
    (with-screen (s 10 5)
      (dolist (case '((0 0 #\A "top-left corner")
                      (9 0 #\B "top-right corner")
                      (0 4 #\C "bottom-left corner")
                      (9 4 #\D "bottom-right corner")
                      (5 2 #\E "center")))
        (destructuring-bind (x y ch desc) case
          (declare (ignore desc))
          (setf (screen-cell s x y)
                (nerimux/terminal/types:make-cell :char ch))
          (expect (char= ch (char-at s x y))))))))

(describe "terminal-suite/screen-cursor-accessors"

  (it "screen-cursor-x-advances-after-write"
    (with-screen (s 20 5)
      (feed s "hello")
      (expect (= 5 (screen-cursor-x s)))))

  (it "screen-cursor-y-advances-after-newline"
    (with-screen (s 20 5)
      (feed s (esc "[3;5H"))   ; move cursor to row 2 (1-based 3), col 4
      (expect (= 2 (screen-cursor-y s)))))

  (it "screen-cursor-x-starts-at-zero"
    (with-screen (s 20 5)
      (expect (= 0 (screen-cursor-x s)))))

  (it "screen-cursor-y-starts-at-zero"
    (with-screen (s 20 5)
      (expect (= 0 (screen-cursor-y s))))))

(describe "terminal-suite/resize"

  (it "resize-larger"
    (with-screen (s 10 5)
      (feed s "hello")
      (screen-resize s 20 8)
      (expect (= 20 (screen-width  s)))
      (expect (= 8  (screen-height s)))
      (expect (string= "hello" (row-string s 0 :end 5)))))

  (it "resize-smaller-clamps-cursor"
    (with-screen (s 20 10)
      (feed s (esc "[10;20H"))  ; cursor near bottom-right
      (screen-resize s 5 3)
      (expect (<= (screen-cursor-x s) 4))
      (expect (<= (screen-cursor-y s) 2))))

  (it "resize-noop"
    (with-screen (s 10 5)
      (feed s "abc")
      (let ((cx (screen-cursor-x s))
            (cy (screen-cursor-y s)))
        (screen-resize s 10 5)
        (expect (string= "abc" (row-string s 0 :end 3)))
        (expect (= cx (screen-cursor-x s)))
        (expect (= cy (screen-cursor-y s))))))

  (it "resize-updates-scroll-region-to-full-height"
    (with-screen (s 10 10)
      (setf (nerimux/terminal/types:screen-scroll-top    s) 2
            (nerimux/terminal/types:screen-scroll-bottom s) 7)
      (screen-resize s 10 15)
      (expect (= 0  (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 14 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "resize-marks-screen-dirty"
    (with-screen (s 10 5)
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
      (screen-resize s 20 8)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-truthy)))

  (it "resize-smaller-preserves-top-left-content"
    (with-screen (s 10 5)
      (feed s "ABCDE")
      (screen-resize s 3 3)
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))
      (expect (char= #\C (char-at s 2 0)))))

  (it "copy-overlapping-cells-copies-top-left-rectangle"
    (with-screen (s 4 4)
      (let ((old-width 3)
            (old-cells (nerimux/terminal/types:%make-blank-cells 9)))
        (loop for i from 0
              for ch across "ABCDEFGHI"
              do (setf (aref old-cells i)
                       (nerimux/terminal/types:make-cell :char ch)))
        (nerimux/terminal/types::%copy-overlapping-cells s old-cells old-width 2 2)
        (expect (char= #\A (char-at s 0 0)))
        (expect (char= #\B (char-at s 1 0)))
        (expect (char= #\D (char-at s 0 1)))
        (expect (char= #\E (char-at s 1 1)))
        (expect (char= #\Space (char-at s 2 0)))
        (expect (char= #\Space (char-at s 0 2))))))

  (it "resize-with-active-alt-cells-leaves-primary-intact"
    (with-screen (s 10 5)
      (feed s (esc "[?1049h"))
      (feed s "ALT")
      (screen-resize s 20 8)
      (expect (= 20 (screen-width  s)))
      (expect (= 8  (screen-height s)))
      (expect (<= (screen-cursor-x s) 19))
      (expect (<= (screen-cursor-y s) 7))
      (expect (nerimux/terminal/types:screen-alt-cells s) :to-be-truthy))))

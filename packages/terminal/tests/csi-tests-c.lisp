(in-package #:nerimux/test/terminal)

(describe "terminal-suite/csi-unknown-sequences"

  (it "csi-unknown-final-byte-does-not-crash"
    (with-screen (s 20 5)
      (feed s "A")
      (finishes (feed s (esc "[99z")))   ; '99z' has no rule
      (feed s "B")
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))))

  (it "csi-dec-private-unknown-mode-no-crash"
    (with-screen (s 20 5)
      (feed s "X")
      (finishes (feed s (esc "[?9876h")))  ; unknown DEC PM set
      (finishes (feed s (esc "[?9876l")))  ; unknown DEC PM reset
      (feed s "Y")
      (expect (char= #\X (char-at s 0 0)))
      (expect (char= #\Y (char-at s 1 0)))))

  (it "csi-multiple-unknown-sequences-in-sequence"
    (with-screen (s 20 5)
      (feed s "start")
      (finishes
        (progn
          (feed s (esc "[1z"))
          (feed s (esc "[2z"))
          (feed s (esc "[3z"))))
      (feed s "end")
      (check-row s 0 "startend"))))

(describe "terminal-suite/decom"

  (it "decom-cup-is-relative-to-scroll-region"
    (with-screen (s 20 10)
      (feed s (esc "[3;6r"))   ; DECSTBM → scroll region rows 3-6 (0-based top=2, bottom=5)
      (feed s (esc "[?6h"))    ; DECOM on → cursor homes to (scroll-top=2, col 0)
      (expect (= 2 (screen-cursor-y s)))
      (expect (= 0 (screen-cursor-x s)))
      (feed s (esc "[2;3H"))   ; CUP row 2 col 3 → origin-relative: row top+1=3, col 2
      (expect (= 3 (screen-cursor-y s)))
      (expect (= 2 (screen-cursor-x s)))))

  (it "decom-confines-cursor-to-scroll-region"
    (with-screen (s 20 10)
      (feed s (esc "[3;6r"))
      (feed s (esc "[?6h"))
      (feed s (esc "[99;1H"))  ; CUP row 99 → clamped to scroll-bottom (row 5)
      (expect (= 5 (screen-cursor-y s)))))

  (it "decom-reset-restores-absolute-cup"
    (with-screen (s 20 10)
      (feed s (esc "[3;6r"))
      (feed s (esc "[?6h"))
      (feed s (esc "[?6l"))    ; DECOM off → cursor homes to (0,0)
      (expect (= 0 (screen-cursor-y s)))
      (feed s (esc "[2;3H"))   ; CUP row 2 col 3 → absolute: row 1, col 2
      (expect (= 1 (screen-cursor-y s))))))

(describe "terminal-suite/cup-row-direct"

  (it "cup-row-non-decom-converts-1-based-to-0-based"
    (with-screen (s 20 10)
      (expect (= 0 (nerimux/terminal/csi::%cup-row s 1)))
      (expect (= 4 (nerimux/terminal/csi::%cup-row s 5)))))

  (it "cup-row-decom-adds-scroll-top-offset"
    (with-screen (s 20 10)
      (feed s (esc "[3;8r"))     ; DECSTBM → top=2, bottom=7 (0-based)
      (feed s (esc "[?6h"))      ; DECOM on
      (expect (= 2 (nerimux/terminal/csi::%cup-row s 1)))
      (expect (= 3 (nerimux/terminal/csi::%cup-row s 2)))))

  (it "cup-row-decom-clamps-to-scroll-bottom"
    (with-screen (s 20 10)
      (feed s (esc "[3;6r"))     ; DECSTBM → top=2, bottom=5 (0-based)
      (feed s (esc "[?6h"))      ; DECOM on
      (expect (= 5 (nerimux/terminal/csi::%cup-row s 99))))))

(describe "terminal-suite/enqueue-helpers"

  (it "enqueue-static-reply-signatures-table"
    (dolist (row (list (list #'nerimux/terminal/csi::enqueue-dsr-reply "[0n"   "dsr → [0n")
                       (list #'nerimux/terminal/csi::enqueue-da1-reply "?1;2c" "da1 → ?1;2c")
                       (list #'nerimux/terminal/csi::enqueue-da2-reply ">1;"   "da2 → >1;")))
      (destructuring-bind (fn expected-sub desc) row
        (declare (ignore desc))
        (with-screen (s 20 5)
          (funcall fn s)
          (expect (some (lambda (r) (search expected-sub r))
                    (nerimux/terminal/types:screen-response-queue s)))))))

  (it "enqueue-cpr-reply-reflects-cursor"
    (with-screen (s 20 10)
      (feed s (esc "[3;5H"))     ; cursor → row 2, col 4 (0-based)
      (nerimux/terminal/csi::enqueue-cpr-reply s)
      (expect (some (lambda (r) (search "[3;5R" r))
                (nerimux/terminal/types:screen-response-queue s))))))

(describe "terminal-suite/xtpushtitle-xtpoptitle"

  (it "xtpushtitle-saves-current-title"
    (with-screen (s 20 5)
      (setf (nerimux/terminal/types:screen-title s) "initial")
      (feed s (esc "[>t"))   ; push
      (expect (equal '("initial") (nerimux/terminal/types:screen-title-stack s)))))

  (it "xtpoptitle-restores-saved-title"
    (with-screen (s 20 5)
      (setf (nerimux/terminal/types:screen-title s) "original")
      (feed s (esc "[>t"))          ; push "original"
      (setf (nerimux/terminal/types:screen-title s) "changed")
      (feed s (esc "[<t"))          ; pop → restore "original"
      (expect (string= "original" (nerimux/terminal/types:screen-title s)))
      (expect (null (nerimux/terminal/types:screen-title-stack s)))))

  (it "xtpoptitle-on-empty-stack-is-noop"
    (with-screen (s 20 5)
      (setf (nerimux/terminal/types:screen-title s) "kept")
      (feed s (esc "[<t"))          ; pop on empty stack — no-op
      (expect (string= "kept" (nerimux/terminal/types:screen-title s)))))

  (it "xtpushtitle-stack-bounded-at-8"
    (with-screen (s 20 5)
      (dotimes (i 9)
        (setf (nerimux/terminal/types:screen-title s) (format nil "t~D" i))
        (feed s (esc "[>t")))
      (expect (<= (length (nerimux/terminal/types:screen-title-stack s)) 8)))))

(describe "terminal-suite/dec-rect-ops"


  (it "decera-erases-interior-rectangle"
    (with-screen (s 10 5)
      (dotimes (y 5)
        (dotimes (x 10)
          (setf (nerimux/terminal/types:screen-cell s x y)
                (nerimux/terminal/types:make-cell :char #\A))))
      (feed s (esc "[2;3;3;6$z"))
      (loop for y from 1 to 2 do
        (loop for x from 2 to 5 do
          (expect (char= #\Space (nerimux/terminal/types:cell-char
                              (nerimux/terminal/types:screen-cell s x y))))))
      (expect (char= #\A (nerimux/terminal/types:cell-char
                      (nerimux/terminal/types:screen-cell s 0 0))))
      (expect (char= #\A (nerimux/terminal/types:cell-char
                      (nerimux/terminal/types:screen-cell s 9 4))))))

  (it "decera-degenerate-rect-is-noop"
    (with-screen (s 10 5)
      (dotimes (y 5)
        (dotimes (x 10)
          (setf (nerimux/terminal/types:screen-cell s x y)
                (nerimux/terminal/types:make-cell :char #\B))))
      (feed s (esc "[3;1;1;5$z"))
      (expect (char= #\B (nerimux/terminal/types:cell-char
                      (nerimux/terminal/types:screen-cell s 0 0))))))


  (it "decfra-fills-rectangle-with-character"
    (with-screen (s 10 5)
      (feed s (esc "[42;1;2;3;5$x"))
      (loop for y from 0 to 2 do
        (loop for x from 1 to 4 do
          (expect (char= #\* (nerimux/terminal/types:cell-char
                          (nerimux/terminal/types:screen-cell s x y))))))
      (expect (char= #\Space (nerimux/terminal/types:cell-char
                          (nerimux/terminal/types:screen-cell s 0 0))))))

  (it "decfra-zero-char-code-uses-space"
    (with-screen (s 10 5)
      (feed s (esc "[0;1;1;2;2$x"))
      (expect (char= #\Space (nerimux/terminal/types:cell-char
                          (nerimux/terminal/types:screen-cell s 0 0))))))


  (it "deccra-copies-rectangle-to-target"
    (with-screen (s 20 5)
      (dotimes (y 2)
        (dotimes (x 3)
          (setf (nerimux/terminal/types:screen-cell s x y)
                (nerimux/terminal/types:make-cell :char #\A))))
      (feed s (esc "[1;1;2;3;0;3;6;0$v"))
      (loop for y from 2 to 3 do
        (loop for x from 5 to 7 do
          (expect (char= #\A (nerimux/terminal/types:cell-char
                          (nerimux/terminal/types:screen-cell s x y))))))
      (loop for y from 0 to 1 do
        (loop for x from 0 to 2 do
          (expect (char= #\A (nerimux/terminal/types:cell-char
                          (nerimux/terminal/types:screen-cell s x y))))))))

  (it "deccra-overlapping-regions-are-correct"
    (with-screen (s 20 5)
      (loop for x from 0 to 4 do
        (setf (nerimux/terminal/types:screen-cell s x 0)
              (nerimux/terminal/types:make-cell :char (code-char (+ (char-code #\A) x)))))
      (feed s (esc "[1;1;1;3;0;1;2;0$v"))
      (expect (char= #\A (nerimux/terminal/types:cell-char (nerimux/terminal/types:screen-cell s 1 0))))
      (expect (char= #\B (nerimux/terminal/types:cell-char (nerimux/terminal/types:screen-cell s 2 0))))
      (expect (char= #\C (nerimux/terminal/types:cell-char (nerimux/terminal/types:screen-cell s 3 0))))
      (expect (char= #\A (nerimux/terminal/types:cell-char (nerimux/terminal/types:screen-cell s 0 0)))))))

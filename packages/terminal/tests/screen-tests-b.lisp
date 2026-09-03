(in-package #:nerimux/test/terminal)

(describe "terminal-suite/copy-mode-slots"

  (it "screen-copy-slots-default-to-nil"
    (with-screen (s 10 5)
      (expect (null (screen-copy-cursor s)))
      (expect (screen-copy-selecting s) :to-be-falsy)
      (expect (null (nerimux/terminal/types:screen-copy-search-term s)))
      (expect (nerimux/terminal/types:screen-copy-line-selection-p s) :to-be-falsy)))

  (it "screen-copy-cursor-can-be-set"
    (with-screen (s 10 5)
      (setf (screen-copy-cursor s) (list 2 3))
      (expect (equal '(2 3) (screen-copy-cursor s)))))

  (it "screen-copy-selecting-can-be-toggled"
    (with-screen (s 10 5)
      (setf (screen-copy-selecting s) t)
      (expect (screen-copy-selecting s) :to-be-truthy)
      (setf (screen-copy-selecting s) nil)
      (expect (screen-copy-selecting s) :to-be-falsy)))

  (it "screen-copy-search-term-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-search-term s) "hello")
      (expect (string= "hello" (nerimux/terminal/types:screen-copy-search-term s)))))

  (it "screen-copy-mark-offset-defaults-zero"
    (with-screen (s 10 5)
      (expect (= 0 (nerimux/terminal/types:screen-copy-mark-offset s)))))

  (it "screen-copy-mark-offset-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-mark-offset s) 7)
      (expect (= 7 (nerimux/terminal/types:screen-copy-mark-offset s))))))

(describe "terminal-suite/alt-screen-slots"

  (it "screen-alt-cursor-defaults-zero"
    (with-screen (s 10 5)
      (expect (= 0 (nerimux/terminal/types:screen-alt-cursor-x s)))
      (expect (= 0 (nerimux/terminal/types:screen-alt-cursor-y s)))))

  (it "screen-alt-cells-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-alt-cells s)))))

  (it "screen-alt-cursor-saved-on-alt-screen-entry"
    (with-screen (s 20 10)
      (feed s (esc "[5;10H"))   ; move cursor to (row=4, col=9)
      (feed s (esc "[?1049h"))  ; enter alt screen
      (expect (= 9 (nerimux/terminal/types:screen-alt-cursor-x s)))
      (expect (= 4 (nerimux/terminal/types:screen-alt-cursor-y s)))))

  (it "alt-screen-1049-saves-and-restores-full-cursor-state"
    (with-screen (s 40 24)
      (feed s (esc "[1;31m"))
      (let ((saved-attrs (nerimux/terminal/types:screen-cur-attrs s))
            (saved-fg    (nerimux/terminal/types:screen-cur-fg    s)))
        (feed s (esc "[?1049h"))
        (feed s (esc "[m"))          ; reset attributes
        (feed s (esc "[10;5H"))      ; move cursor
        (feed s (esc "[?1049l"))
        (expect (= 0 (nerimux/terminal/types:screen-cursor-x s)))
        (expect (= saved-attrs (nerimux/terminal/types:screen-cur-attrs s)))
        (expect (= saved-fg (nerimux/terminal/types:screen-cur-fg s)))))))

(describe "terminal-suite/response-queue-suite"

  (it "response-queue-starts-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-response-queue s)))))

  (it "response-queue-can-be-pushed-and-drained"
    (with-screen (s 10 5)
      (push "response-a" (nerimux/terminal/types:screen-response-queue s))
      (push "response-b" (nerimux/terminal/types:screen-response-queue s))
      (let ((items (nreverse (nerimux/terminal/types:screen-response-queue s))))
        (setf (nerimux/terminal/types:screen-response-queue s) nil)
        (expect (equal '("response-a" "response-b") items)))))

  (it "response-queue-cleared-after-drain"
    (with-screen (s 10 5)
      (push "data" (nerimux/terminal/types:screen-response-queue s))
      (setf (nerimux/terminal/types:screen-response-queue s) nil)
      (expect (null (nerimux/terminal/types:screen-response-queue s))))))

(describe "terminal-suite/origin-mode-slot-suite"

  (it "screen-origin-mode-defaults-false"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-falsy)))

  (it "screen-origin-mode-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-origin-mode s) t)
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-truthy)
      (setf (nerimux/terminal/types:screen-origin-mode s) nil)
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-falsy)))

  (it "screen-origin-mode-enabled-by-sequence"
    (with-screen (s 10 5)
      (feed s (esc "[?6h"))
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-truthy)))

  (it "screen-origin-mode-disabled-by-sequence"
    (with-screen (s 10 5)
      (feed s (esc "[?6h"))
      (feed s (esc "[?6l"))
      (expect (nerimux/terminal/types:screen-origin-mode s) :to-be-falsy))))

(describe "terminal-suite/tab-stops-slot-suite"

  (it "screen-tab-stops-defaults-to-sentinel"
    (with-screen (s 80 5)
      (expect (eq :default (nerimux/terminal/types:screen-tab-stops s)))))

  (it "screen-tab-stops-can-be-set-to-list"
    (with-screen (s 80 5)
      (setf (nerimux/terminal/types:screen-tab-stops s) '(0 8 16 24))
      (expect (equal '(0 8 16 24) (nerimux/terminal/types:screen-tab-stops s)))))

  (it "screen-tab-stops-hts-materialises-sentinel"
    (with-screen (s 80 5)
      (feed s (esc "[5G"))   ; CHA — move cursor to column 5 (1-based), i.e. 0-based col 4
      (feed s (esc "H"))     ; ESC H = HTS (set tab stop at current cursor column)
      (let ((stops (nerimux/terminal/types:screen-tab-stops s)))
        (expect (listp stops))
        (expect (member 4 stops))))))

(describe "terminal-suite/screen-lock-suite"

  (it "screen-lock-is-present-and-non-nil"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-lock s) :to-be-truthy)))

  (it "screen-lock-can-be-acquired-and-released"
    (with-screen (s 10 5)
      (let ((lock (nerimux/terminal/types:screen-lock s)))
        (finishes
          (cl-concurrent-kit:with-lock-held (lock) t)))))

  (it "screen-lock-satisfies-the-declared-lock-type"
    (with-screen (s 10 5)
      (expect (typep (nerimux/terminal/types:screen-lock s)
                     'cl-concurrent-kit:lock)
              :to-be-truthy))))

(describe "terminal-suite/screen-cells-parser-suite"

  (it "screen-cells-returns-simple-vector"
    (with-screen (s 8 4)
      (let ((cells (nerimux/terminal/types:screen-cells s)))
        (expect (simple-vector-p cells))
        (expect (= (* 8 4) (length cells))))))

  (it "screen-cells-all-elements-are-cells"
    (with-screen (s 4 3)
      (let ((cells (nerimux/terminal/types:screen-cells s)))
        (dotimes (i (* 4 3))
          (expect (nerimux/terminal/types:cell-p (aref cells i)))
          (expect (char= #\Space (cell-char (aref cells i))))))))

  (it "screen-parser-is-wired-ground-state"
    (with-screen (s 10 5)
      (expect (functionp (nerimux/terminal/types:screen-parser s)))
      (screen-process-bytes s #(65))      ; 65 = #\A
      (expect (char= #\A (char-at s 0 0))))))

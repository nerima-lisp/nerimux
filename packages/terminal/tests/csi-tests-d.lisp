(in-package #:nerimux/test/terminal)

(describe "terminal-suite/rep"

  (it "rep-repeats-last-char"
    (with-screen (s 20 5)
      (feed s "A")             ; writes 'A' at col 0, cursor at col 1
      (feed s (esc "[3b"))     ; REP 3: writes 'A' 3 more times
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\A (char-at s 1 0)))
      (expect (char= #\A (char-at s 2 0)))
      (expect (char= #\A (char-at s 3 0)))
      (check-cursor s 4 0)))

  (it "rep-noop-when-no-last-char"
    (with-screen (s 20 5)
      (expect (null (nerimux/terminal/types:screen-last-char s)))
      (feed s (esc "[3b"))     ; REP 3 — no-op
      (check-cursor s 0 0)
      (expect (row-blank-p s 0))))

  (it "rep-uses-last-printed-char"
    (with-screen (s 20 5)
      (feed s "AB")            ; writes A at 0, B at 1; last-char = B
      (expect (char= #\B (nerimux/terminal/types:screen-last-char s)))
      (feed s (esc "[2b"))     ; REP 2: writes B twice more
      (expect (char= #\B (char-at s 2 0)))
      (expect (char= #\B (char-at s 3 0))))))

(describe "terminal-suite/da-response"

  (it "da1-response"
    (with-screen (s 20 5)
      (expect (null (nerimux/terminal/types:screen-response-queue s)))
      (feed s (esc "[c"))        ; DA1
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (consp q))
        (expect (some (lambda (r) (search "?1;2c" r)) q)))))

  (it "da2-response"
    (with-screen (s 20 5)
      (feed s (esc "[>c"))       ; DA2
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (consp q))
        (expect (some (lambda (r) (search ">1;" r)) q)))))

  (it "xtversion-reports-nerimux-version"
    (with-screen (s 20 5)
      (feed s (esc "[>q"))       ; XTVERSION
      (expect (string= (format nil "~CP>|nerimux ~A~C\\"
                               #\Escape
                               (nerimux/version:version-string)
                               #\Escape)
                       (first (nerimux/terminal/types:screen-response-queue s))))))

  (it "da3-response"
    (with-screen (s 20 5)
      (feed s (esc "[=c"))       ; DA3
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (consp q))
        (expect (some (lambda (r) (search "!|00000000" r)) q)))))


  (it "decrqm-reports-set-mode"
    (with-screen (s 20 5)
      (feed s (esc "[?25$p"))
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (search (format nil "~C[?25;1$y" #\Escape) r)) q)))))

  (it "decrqm-reports-reset-mode"
    (with-screen (s 20 5)
      (feed s (esc "[?25l"))     ; hide cursor
      (feed s (esc "[?25$p"))
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (search (format nil "~C[?25;2$y" #\Escape) r)) q)))))

  (it "decrqm-unknown-mode-reports-zero"
    (with-screen (s 20 5)
      (feed s (esc "[?9999$p"))
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (search (format nil "~C[?9999;0$y" #\Escape) r)) q)))))

  (it "decrqm-reports-decscnm-mode-5"
    (with-screen (s 20 5)
      (feed s (esc "[?5$p"))
      (expect (some (lambda (r) (search (format nil "~C[?5;2$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s)))
      (feed s (esc "[?5h"))
      (feed s (esc "[?5$p"))
      (expect (some (lambda (r) (search (format nil "~C[?5;1$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s)))))

  (it "decrqm-reports-decawm-mode-7"
    (with-screen (s 20 5)
      (feed s (esc "[?7$p"))
      (expect (some (lambda (r) (search (format nil "~C[?7;1$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s)))
      (feed s (esc "[?7l"))
      (feed s (esc "[?7$p"))
      (expect (some (lambda (r) (search (format nil "~C[?7;2$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s)))))

  (it "mouse-reporting-modes-accepted-and-decrqm-reports-unrecognised"
    (with-screen (s 20 5)
      (dolist (mode '(1000 1002 1003 1006))
        (finishes (feed s (esc "[?~Dh" mode)))
        (finishes (feed s (esc "[?~Dl" mode)))
        (setf (nerimux/terminal/types:screen-response-queue s) nil)
        (feed s (esc "[?~D$p" mode))
        (expect (some (lambda (r) (search (format nil "~C[?~D;0$y" #\Escape mode) r))
                      (nerimux/terminal/types:screen-response-queue s))))))

  (it "decrqm-ansi-reports-irm-mode-4"
    (with-screen (s 20 5)
      (feed s (esc "[4$p"))
      (expect (some (lambda (r) (search (format nil "~C[4;2$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s)))
      (feed s (esc "[4h"))
      (feed s (esc "[4$p"))
      (expect (some (lambda (r) (search (format nil "~C[4;1$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s)))))

  (it "decrqm-ansi-reports-lnm-mode-20"
    (with-screen (s 20 5)
      (feed s (esc "[20h"))
      (feed s (esc "[20$p"))
      (expect (some (lambda (r) (search (format nil "~C[20;1$y" #\Escape) r))
                    (nerimux/terminal/types:screen-response-queue s))))))

(describe "terminal-suite/xtwinops"

  (it "xtwinops-18-reports-text-area-chars"
    (with-screen (s 20 5)
      (feed s (esc "[18t"))
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (string= (format nil "~C[8;5;20t" #\Escape) r)) q)))))

  (it "xtwinops-19-reports-screen-chars"
    (with-screen (s 20 5)
      (feed s (esc "[19t"))
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (string= (format nil "~C[9;5;20t" #\Escape) r)) q)))))

  (it "xtwinops-resize-op-no-reply"
    (with-screen (s 20 5)
      (feed s (esc "[8;24;80t"))
      (expect (null (nerimux/terminal/types:screen-response-queue s)))))


  (it "cpr-at-home-replies-1-1"
    (with-screen (s 20 5)
      (feed s (esc "[6n"))       ; CPR — report cursor position
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (consp q))
        (expect (some (lambda (r) (search "[1;1R" r)) q)))))

  (it "cpr-reports-moved-cursor-position"
    (with-screen (s 20 5)
      (feed s (esc "[3;5H"))     ; CUP → row 3, col 5 (1-based)
      (feed s (esc "[6n"))       ; CPR
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (search "[3;5R" r)) q)))))

  (it "cpr-in-decom-mode-reports-relative-row"
    (with-screen (s 20 10)
      (feed s (esc "[3;8r"))    ; DECSTBM: scroll region rows 3..8 (1-based)
      (feed s (esc "[?6h"))     ; DECOM on — cursor is now relative to margin
      (feed s (esc "[3;1H"))
      (feed s (esc "[6n"))      ; CPR
      (let ((q (nerimux/terminal/types:screen-response-queue s)))
        (expect (some (lambda (r) (search "[3;1R" r)) q)))))


  (it "da-response-table"
    (dolist (entry '(("[c"  "?1;2c")    ; DA1 signature
                     ("[>c" ">1;")))     ; DA2 signature
      (let ((seq (first entry))
            (sig (second entry)))
        (with-screen (s 20 5)
          (feed s (esc seq))
          (let ((q (nerimux/terminal/types:screen-response-queue s)))
            (expect (consp q))
            (expect (some (lambda (r) (search sig r)) q)))))))


  (it "rep-count-zero-is-noop"
    (with-screen (s 20 5)
      (feed s "X")
      (let ((cx (screen-cursor-x s)))
        (feed s (esc "[0b"))
        (expect (= cx (screen-cursor-x s)))))))

(describe "terminal-suite/decrqm-internal"

  (it "decrqm-flag-code-table"
    (expect (= 1 (nerimux/terminal/csi::%decrqm-flag-code t)))
    (expect (= 2 (nerimux/terminal/csi::%decrqm-flag-code nil))))

  (it "decrqm-ansi-mode-state-irm-table"
    (dolist (row '((t   1 "insert-mode T → 1 (set)")
                   (nil 2 "insert-mode NIL → 2 (reset)")))
      (destructuring-bind (insert-mode-val expected desc) row
        (declare (ignore desc))
        (with-screen (s 20 5)
          (setf (nerimux/terminal/types:screen-insert-mode s) insert-mode-val)
          (expect (= expected (nerimux/terminal/csi::%decrqm-ansi-mode-state s 4)))))))

  (it "decrqm-ansi-mode-state-lnm-set"
    (with-screen (s 20 5)
      (setf (nerimux/terminal/types:screen-newline-mode s) t)
      (expect (= 1 (nerimux/terminal/csi::%decrqm-ansi-mode-state s 20)))))

  (it "decrqm-ansi-mode-state-unknown-returns-0"
    (with-screen (s 20 5)
      (expect (= 0 (nerimux/terminal/csi::%decrqm-ansi-mode-state s 999))))))

(describe "terminal-suite/da3-xtversion-direct"

  (it "enqueue-reply-substring-table"
    (dolist (row (list (list #'nerimux/terminal/csi::enqueue-da3-reply      "!|00000000" "DA3 reply")
                       (list #'nerimux/terminal/csi::enqueue-xtversion-reply "nerimux"    "XTVERSION reply")))
      (destructuring-bind (fn expected desc) row
        (declare (ignore desc))
        (with-screen (s 20 5)
          (funcall fn s)
          (expect (some (lambda (r) (search expected r))
                        (nerimux/terminal/types:screen-response-queue s))))))))

(describe "terminal-suite/xtwinops-direct"

  (it "enqueue-xtwinops-reply-size-ops-table"
    (dolist (row '((18 "[8;8;30t" "op 18 text-area report")
                   (19 "[9;8;30t" "op 19 screen report")))
      (destructuring-bind (op expected desc) row
        (declare (ignore desc))
        (with-screen (s 30 8)
          (nerimux/terminal/csi::enqueue-xtwinops-reply s op)
          (expect (some (lambda (r) (search expected r))
                        (nerimux/terminal/types:screen-response-queue s)))))))

  (it "enqueue-xtwinops-reply-op-99-no-reply"
    (with-screen (s 20 5)
      (nerimux/terminal/csi::enqueue-xtwinops-reply s 99)
      (expect (null (nerimux/terminal/types:screen-response-queue s))))))

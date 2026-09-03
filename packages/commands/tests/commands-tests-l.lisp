(in-package #:nerimux/test/commands)

;;;; commands tests — part L: copy-mode-exit rect-select reset, rectangle-text.
(describe "commands-suite"

  ;; copy-mode-exit clears screen-copy-rect-select-p.
  (it "copy-mode-exit-resets-rect-select"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t)
      (nerimux/commands::copy-mode-exit s)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)))

  ;;; ── rectangle selection text ─────────────────────────────────────────────────

  ;; When rect-select is T, yank uses column bounds from mark and cursor on
  ;; every row, and the assembled text goes out as OSC 52 (R3.1: no paste
  ;; buffer — the clipboard-queue is the only sink for a yank).
  (it "copy-mode-yank-rectangle-uses-fixed-columns"
    (let ((s (make-screen 10 5)))
      ;; Write row 0 "abcde" and row 1 "ABCDE" using CR+LF to ensure row 1 starts at col 0.
      (feed s (format nil "abcde~C~CABCDE" #\Return #\Linefeed))
      (nerimux/commands::copy-mode-enter s)
      ;; Rectangle col 1-3, rows 0-1.
      ;; %extract-row-chars from-col=1 to-col=3 → 2 chars at cols 1 and 2.
      ;; Row 0: "bc"; row 1: "BC".
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t
            (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) (cons 0 1)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 3))
      (nerimux/commands::copy-mode-yank s)
      (let* ((q   (nerimux/terminal/types:screen-clipboard-queue s))
             (seq (first q))
             (expected (nerimux/terminal/parser:osc52-clipboard-sequence
                        (format nil "bc~%BC"))))
        (expect (= 1 (length q)))
        (expect (string= expected seq))))))

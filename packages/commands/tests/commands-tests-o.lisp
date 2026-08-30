(in-package #:nerimux/test/commands)

;;;; Commands tests — part XV: selection-bounds scrollback, word/paragraph nav, scroll-middle.

(describe "commands-suite"

  ;; ── %selection-bounds scrollback spanning (virtual-row correctness) ──────────

  ;; When the user begins a selection and then scrolls, %selection-bounds must use
  ;; virtual (absolute scrollback) rows so the selected TEXT does not shift.
  ;; Regression test for the mark-offset fix: mark-row is a viewport row stored
  ;; at the time of begin-selection; after scrolling by delta lines the mark must
  ;; still refer to the same content.
  ;; The mark is placed at (row=2, col=3) — non-zero col so the mark row contributes
  ;; chars to %selection-text.  After scroll, with OLD (buggy) code the mark row would
  ;; be viewport row 2 at offset=1 = live-grid row 1 = 'DDD'.  With the NEW code, the
  ;; mark virtual row remains vrow=4 = live-grid row 2 = 'EEE'.
  (it "selection-bounds-after-scroll-uses-virtual-rows"
    (let ((s (make-screen 4 3)))        ; 4 cols, 3 rows
      ;; Feed 5 lines: scrollback=[BBB,AAA] (newest first), grid=[CCC,DDD,EEE].
      (feed-lines s "AAA" "BBB" "CCC" "DDD" "EEE")
      (nerimux/commands::copy-mode-enter s)
      ;; Enter at offset=0, cursor at live-grid bottom (row 2, col 0).
      (expect (= 0 (screen-copy-offset s)))
      ;; Move cursor to col 3 to give the mark a non-zero column.
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 3))
      ;; Begin selection: mark=(2, 3), mark-offset=0.
      (nerimux/commands::copy-mode-begin-selection s)
      (expect (= 0 (nerimux/terminal/types:screen-copy-mark-offset s)))
      ;; Scroll back 1 line into scrollback: offset becomes 1.
      (nerimux/commands::copy-mode-scroll s 1)
      (expect (= 1 (screen-copy-offset s)))
      ;; Move cursor to viewport row 0, col 0 (newest scrollback row).
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      ;; Virtual row check: sb-n=2, mark-vrow=2+2-0=4 (EEE), cursor-vrow=2+0-1=1 (BBB).
      (multiple-value-bind (start-vrow end-vrow start-col end-col)
          (nerimux/commands::%selection-bounds s)
        (declare (ignore start-col end-col))
        (expect (= 1 start-vrow))
        (expect (= 4 end-vrow)))
      ;; %selection-text: vrow 1=BBB, vrow 2=CCC, vrow 3=DDD, vrow 4 cols 0-3 = EEE.
      ;; With the OLD buggy code, vrow 4 would instead be DDD (viewport row 2 at offset=1
      ;; = live-grid row 1 = DDD instead of EEE).
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (and text (search "BBB" text)))
        (expect (and text (search "EEE" text)))))))

(in-package #:nerimux/test/terminal)

;;;; modes tests — part B: set-cursor-shape, bell-pending, designate-charset/title,
;;;; reset-terminal-modes, DECNKM, DECOM, origin-mode, screen-display-cell
;;;; continuation, DECSTBM, mouse/focus-reporting edge cases.

;;; ── SUITE: set-cursor-shape ──────────────────────────────────────────────────
;;;
;;; set-cursor-shape wraps DECSCUSR: clamps the shape value to [0,6] and stores
;;; it in screen-cursor-shape.

(describe "terminal-suite/set-cursor-shape-suite"

  ;; set-cursor-shape stores values in [0,6] unchanged.
  (it-each ((0 0 "default blinking block")
            (1 1 "blinking block")
            (2 2 "steady block")
            (3 3 "blinking underline")
            (4 4 "steady underline")
            (5 5 "blinking bar")
            (6 6 "steady bar"))
      "set-cursor-shape-stores-valid-values: ~*~*~A"
      (input expected desc)
    (declare (ignore desc))
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor-shape s input)
      (expect (= expected (nerimux/terminal/types:screen-cursor-shape s)))))

  ;; set-cursor-shape clamps values > 6 to 6.
  (it "set-cursor-shape-clamps-above-six-to-six"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor-shape s 99)
      (expect (= 6 (nerimux/terminal/types:screen-cursor-shape s)))))

  ;; set-cursor-shape clamps negative values to 0.
  (it "set-cursor-shape-clamps-below-zero-to-zero"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-cursor-shape s -1)
      (expect (= 0 (nerimux/terminal/types:screen-cursor-shape s))))))

;;; ── SUITE: set-bell-pending and screen-consume-bell ─────────────────────────
;;;
;;; set-bell-pending sets screen-bell-pending to T.
;;; screen-consume-bell returns T and clears the flag; returns NIL when not set.

(describe "terminal-suite/bell-pending-suite"

  ;; set-bell-pending sets screen-bell-pending to T.
  (it "set-bell-pending-sets-flag"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (nerimux/terminal/actions:set-bell-pending s)
      (expect (nerimux/terminal/types:screen-bell-pending s))))

  ;; screen-consume-bell returns T and clears the bell-pending flag.
  (it "screen-consume-bell-returns-true-and-clears-flag"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-bell-pending s)
      (let ((result (nerimux/terminal/types:screen-consume-bell s)))
        (expect result :to-be-truthy)
        (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy))))

  ;; screen-consume-bell returns NIL without side effects when bell is not pending.
  (it "screen-consume-bell-returns-nil-when-not-pending"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy)))

  ;; A BEL byte (0x07) fed to the emulator sets screen-bell-pending.
  (it "bell-byte-sets-pending-via-emulator"
    (with-screen (s 10 5)
      (screen-process-bytes s (vector 7))  ; BEL = 0x07
      (expect (nerimux/terminal/types:screen-bell-pending s)))))

;;; ── SUITE: designate-charset and set-screen-title ─────────────────────────────
;;;
;;; designate-charset (G0, the default active slot) stores the character set
;;; keyword into screen-charset.
;;; set-screen-title stores the OSC window title string.

(describe "terminal-suite/set-charset-set-title-suite"

  ;; designate-charset :g0 :ascii sets screen-charset to :ascii.
  (it "set-charset-stores-ascii-keyword"
    (with-screen (s 10 5)
      ;; Start with dec-graphics, then reset to ascii
      (setf (nerimux/terminal/types:screen-charset s) :dec-graphics)
      (nerimux/terminal/actions:designate-charset s :g0 :ascii)
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  ;; designate-charset :g0 :dec-graphics sets screen-charset to :dec-graphics.
  (it "set-charset-stores-dec-graphics-keyword"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:designate-charset s :g0 :dec-graphics)
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  ;; set-screen-title stores the given title in screen-title.
  (it "set-screen-title-stores-string"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "my-window")
      (expect (string= "my-window" (nerimux/terminal/types:screen-title s)))))

  ;; set-screen-title accepts an empty string.
  (it "set-screen-title-stores-empty-string"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:set-screen-title s "first")
      (nerimux/terminal/actions:set-screen-title s "")
      (expect (string= "" (nerimux/terminal/types:screen-title s)))))

  ;; OSC 0 ; title ST sets screen-title via the emulator.
  (it "set-screen-title-via-osc-sequence"
    (with-screen (s 20 5)
      ;; OSC 0 ; hello BEL — OSC title sequence
      (feed s (format nil "~C]0;hello~C" #\Escape (code-char 7)))
      (expect (string= "hello" (nerimux/terminal/types:screen-title s))))))

;;; ── SUITE: reset-terminal-modes ──────────────────────────────────────────────
;;;
;;; reset-terminal-modes resets cursor visibility, autowrap, charset, and scroll
;;; region to VT100 defaults without touching the cell grid.

(describe "terminal-suite/reset-terminal-modes-suite"

  ;; reset-terminal-modes restores cursor-visible and autowrap to T, and charset to :ascii.
  (it "reset-terminal-modes-restores-flags"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cursor-visible s) nil
            (nerimux/terminal/types:screen-autowrap s)        nil
            (nerimux/terminal/types:screen-charset s)         :dec-graphics)
      (nerimux/terminal/actions:reset-terminal-modes s)
      (expect (nerimux/terminal/types:screen-cursor-visible s))
      (expect (nerimux/terminal/types:screen-autowrap s))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  ;; reset-terminal-modes resets scroll-top to 0 and scroll-bottom to height-1.
  (it "reset-terminal-modes-restores-scroll-region-to-full-screen"
    (with-screen (s 10 8)
      ;; Restrict the scroll region
      (setf (nerimux/terminal/types:screen-scroll-top    s) 2
            (nerimux/terminal/types:screen-scroll-bottom s) 5)
      (nerimux/terminal/actions:reset-terminal-modes s)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 7 (nerimux/terminal/types:screen-scroll-bottom s)))))

  ;; reset-terminal-modes does not erase the cell grid.
  (it "reset-terminal-modes-does-not-clear-cells"
    (with-screen (s 10 5)
      (feed s "hello")
      (nerimux/terminal/actions:reset-terminal-modes s)
      ;; The text written before reset must survive
      (expect (char= #\h (char-at s 0 0))))))

;;; ── SUITE: enter/exit alt-screen direct actions ──────────────────────────────
;;;
;;; enter-alt-screen and exit-alt-screen are called directly to verify the
;;; no-op guard (enter when already in alt, exit when not in alt).

(describe "terminal-suite/alt-screen-direct-suite"

  ;; enter-alt-screen is a no-op when called while the alt screen is already active.
  (it "enter-alt-screen-is-noop-when-already-active"
    (with-screen (s 10 5)
      (feed s "primary")
      (nerimux/terminal/actions:enter-alt-screen s)    ; first entry — saves grid
      ;; Capture the saved alt-cells reference before the second call
      (let ((saved-alt-cells (nerimux/terminal/types:screen-alt-cells s)))
        (nerimux/terminal/actions:enter-alt-screen s)  ; second call — no-op
        ;; alt-cells must still point to the same grid snapshot
        (expect (eq saved-alt-cells (nerimux/terminal/types:screen-alt-cells s))))))

  ;; exit-alt-screen with no prior save falls back to erase-display mode 2.
  (it "exit-alt-screen-clears-to-blank-when-no-saved-grid"
    (with-screen (s 10 5)
      (feed s "hello")
      ;; Call exit-alt-screen without ever entering: alt-cells is NIL
      (nerimux/terminal/actions:exit-alt-screen s)
      ;; The erase-display mode 2 fallback should have cleared all cells
      (dotimes (y 5)
        (expect (row-blank-p s y))))))

;;; ── SUITE: enter/exit alt-screen direct content verification ─────────────────

(describe "terminal-suite/alt-screen-content-suite"

  ;; enter-alt-screen replaces the live grid with a fresh blank grid.
  (it "enter-alt-screen-installs-blank-grid"
    (with-screen (s 10 5)
      (feed s "primary")
      (nerimux/terminal/actions:enter-alt-screen s)
      ;; All cells in the new (alt) grid must be blank
      (dotimes (y 5)
        (expect (row-blank-p s y)))))

  ;; exit-alt-screen restores the cursor position saved at enter time.
  (it "exit-alt-screen-restores-primary-cursor-position"
    (with-screen (s 20 10)
      ;; Position cursor at (7, 3), enter alt, move cursor, exit
      (nerimux/terminal/actions:set-cursor s 7 3)
      (nerimux/terminal/actions:enter-alt-screen s)
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:exit-alt-screen s)
      (check-cursor s 7 3))))

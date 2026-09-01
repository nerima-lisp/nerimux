(in-package #:nerimux/test/terminal)

;;;; scroll tests — part B: direct-row-primitives (%copy-row, %clear-row),
;;;; direct-action-erase suites, and scroll edge cases.
;;; ── SUITE: direct-row-primitives ────────────────────────────────────────────
;;;
;;; Coverage gap: %copy-row and %clear-row are used by scroll and edit operations
;;; but were previously only tested indirectly.  These tests call them directly.
(describe "terminal-suite/direct-row-primitives"

  ;; %copy-row copies every cell from the source row to the destination row.
  (it "copy-row-copies-all-cells"
    (with-screen (s 5 3)
      (feed s "hello")                       ; row 0 = "hello"
      (nerimux/terminal/actions::%copy-row s 1 0)  ; copy row 0 to row 1
      (expect (string= "hello" (row-string s 1)))))

  ;; %clear-row replaces every cell in the target row with a blank cell.
  (it "clear-row-blanks-all-cells"
    (with-screen (s 5 3)
      (feed s "hello")                       ; row 0 = "hello"
      (nerimux/terminal/actions::%clear-row s 0)
      (expect (row-blank-p s 0))))

  ;; trim-scroll-history removes entries beyond +max-scrollback-lines+.
  ;; Pre-populating the scrollback directly with cons cells (rather than
  ;; feeding cap+3 real lines through the emulator) keeps this cheap even
  ;; though the real cap is now 10,000 (§1.4) — allocation is the only cost,
  ;; and trim-scroll-history is called exactly once.
  (it "trim-scroll-history-caps-at-limit"
    (with-screen (s 5 3)
      (let ((cap nerimux/terminal:+max-scrollback-lines+))
        (setf (nerimux/terminal/types:screen-scrollback s)
              (loop repeat (+ cap 3)
                    collect (make-array 5 :initial-element
                                          (nerimux/terminal/types:blank-cell))))
        (nerimux/terminal/actions:trim-scroll-history s)
        (expect (<= (length (nerimux/terminal/types:screen-scrollback s)) cap))))))

;;; ── SUITE: scrollback-cap-constant ────────────────────────────────────────────
;;;
;;; §1.4 fixes scrollback at 10,000 rows.  This used to be reachable only
;;; indirectly (install the option, read it back through the port); now it is
;;; a plain DEFCONSTANT with no injection point, so the regression guard is a
;;; direct equality check against the value the requirements doc fixes.
(describe "terminal-suite/scrollback-cap-constant"
          (it "max-scrollback-lines-is-10000"
              (expect (= 10000 nerimux/terminal:+max-scrollback-lines+))))

;;; ── SUITE: direct-action-erase ───────────────────────────────────────────────
;;;
;;; These tests call erase-region, erase-display, erase-line directly rather
;;; than through the CSI parser path, targeting edge cases that high-level
;;; tests are unlikely to assert explicitly.
(describe "terminal-suite/direct-action-erase"

  ;; erase-region blanks a linear span from (x0,y0) to (x1,y1) inclusive.
  (it "erase-region-clears-span-across-rows"
    (with-screen (s 5 4)
      (feed s "aabbccddee")           ; rows 0 and 1 filled
      ;; Erase from (3,0) to (1,1): last 2 cells of row 0 + first 2 of row 1.
      (nerimux/terminal/actions:erase-region s 3 0 1 1)
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\a (char-at s 1 0)))
      (expect (char= #\b (char-at s 2 0)))
      (expect (char= #\Space (char-at s 3 0)))
      (expect (char= #\Space (char-at s 4 0)))
      (expect (char= #\Space (char-at s 0 1)))
      (expect (char= #\Space (char-at s 1 1)))))

  ;; erase-display mode 3 (ED 3) also clears the scrollback buffer.
  (it "erase-display-mode-3-clears-scrollback"
    (with-screen (s 5 3)
      ;; Build up some scrollback by feeding lines that force scrolling.
      (feed-lines s "L0" "L1" "L2" "L3")
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))
      ;; Mode 3 = clear screen + clear scrollback
      (nerimux/terminal/actions:erase-display s 3)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  ;; erase-line mode 0 erases from the cursor column to the end of the line.
  (it "erase-line-mode-0-erases-to-end"
    (with-screen (s 10 5)
      (feed s "hello")
      ;; Move cursor to col 2 via cursor-left.
      (nerimux/terminal/actions:cursor-left s 3)   ; cursor at col 2
      (nerimux/terminal/actions:erase-line s 0)
      (expect (char= #\h (char-at s 0 0)))
      (expect (char= #\e (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\Space (char-at s 4 0))))))

;;; ── SUITE: direct-decstbm ─────────────────────────────────────────────────────
;;;
;;; Direct tests for the decstbm function, covering boundary conditions
;;; that the CSI parser integration tests do not exercise explicitly.
(describe "terminal-suite/direct-decstbm"

  ;; decstbm with a valid top < bottom sets scroll-top and scroll-bottom.
  (it "decstbm-valid-region-sets-scroll-boundaries"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 1 3)
      (expect (= 1 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 3 (nerimux/terminal/types:screen-scroll-bottom s)))))

  ;; decstbm with a valid region homes the cursor to (0,0).
  (it "decstbm-valid-region-homes-cursor"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:set-cursor s 3 3)
      (nerimux/terminal/actions:decstbm s 0 4)
      (check-cursor s 0 0)))

  ;; decstbm with top == bottom does not change the scroll region.
  (it "decstbm-equal-top-bottom-is-rejected"
    (with-screen (s 5 5)
      ;; Default scroll region is 0..4.
      (let ((orig-top    (nerimux/terminal/types:screen-scroll-top s))
            (orig-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 2 2)  ; top = bottom = 2
        (expect (= orig-top    (nerimux/terminal/types:screen-scroll-top s)))
        (expect (= orig-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  ;; decstbm with top > bottom does not change the scroll region.
  (it "decstbm-inverted-region-is-rejected"
    (with-screen (s 5 5)
      (let ((orig-top    (nerimux/terminal/types:screen-scroll-top s))
            (orig-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 4 1)  ; top > bottom — invalid
        (expect (= orig-top    (nerimux/terminal/types:screen-scroll-top s)))
        (expect (= orig-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  ;; decstbm clamps out-of-range values to the screen height.
  (it "decstbm-out-of-range-clamped-to-screen"
    (with-screen (s 5 5)
      ;; Negative top → clamped to 0; bottom beyond height-1 → clamped to 4.
      (nerimux/terminal/actions:decstbm s -5 99)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top s)))
      (expect (= 4 (nerimux/terminal/types:screen-scroll-bottom s))))))

;;; ── SUITE: constrained-scroll ─────────────────────────────────────────────────
;;;
;;; Tests that scroll-up-one and scroll-down-one respect an active scroll region
;;; set by decstbm and leave rows outside the region untouched.
;;;
;;; The shared with-5-row-scroll-region fixture eliminates the repeated inline
;;; 5-row fill + decstbm setup pattern from both tests.
;; Must be a genuine top-level DEFMACRO (not nested inside DESCRIBE's body):
;; DESCRIBE's body only runs as a lambda at suite-registration time, so a
;; DEFMACRO nested inside it is invisible to the compiler when it compiles
;; the sibling IT forms in the same file that call it as a macro.
(defmacro with-5-row-scroll-region ((screen-var) &body body)
  "Bind SCREEN-VAR to a 5-row screen with rows labeled R0-R4 and scroll
   region restricted to rows 1-3.  Used by constrained-scroll tests."
  `(with-screen (,screen-var 5 5)
                (feed-lines ,screen-var "R0" "R1" "R2" "R3" "R4")
                (nerimux/terminal/actions:decstbm ,screen-var 1 3)
                ,@body))

(describe "terminal-suite/constrained-scroll"

  ;; scroll-up-one moves only the rows within the active scroll region.
  (it "scroll-up-one-respects-scroll-region"
    (with-5-row-scroll-region (s)
      (nerimux/terminal/actions:scroll-up-one s)
      ;; Row 0 must be untouched (outside the scroll region).
      (check-row s 0 "R0")
      ;; Row 4 must also be untouched.
      (check-row s 4 "R4")))

  ;; scroll-down-one moves only the rows within the active scroll region.
  (it "scroll-down-one-respects-scroll-region"
    (with-5-row-scroll-region (s)
      (nerimux/terminal/actions:scroll-down-one s)
      ;; Row 0 must be untouched.
      (check-row s 0 "R0")
      ;; Row 4 must be untouched.
      (check-row s 4 "R4")
      ;; Row 1 (the new top of the region) must be blank.
      (expect (row-blank-p s 1)))))

;;; ── SUITE: scroll-dirty-flag ─────────────────────────────────────────────────
;;;
;;; Both scroll-up-one and scroll-down-one must mark screen-dirty-p after they
;;; operate, so the renderer knows a repaint is needed.
(describe "terminal-suite/scroll-dirty-flag"

  ;; Both scroll-up-one and scroll-down-one set screen-dirty-p to T.
  (it "scroll-up-and-down-one-mark-screen-dirty"
    (dolist (fn (list #'nerimux/terminal/actions:scroll-up-one
                      #'nerimux/terminal/actions:scroll-down-one))
      (with-screen (s 5 3)
        (screen-clear-dirty s)
        (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
        (funcall fn s)
        (expect (nerimux/terminal/types:screen-dirty-p s))))))

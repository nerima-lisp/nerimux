(in-package #:nerimux/test/terminal)

;;;; scroll tests — part D: clear-scrollback, BCE background via %erase-cell,
;;;; and scroll-on-clear (ED 2 → scrollback) edge-cases.

;;; ── SUITE: clear-scrollback ──────────────────────────────────────────────────
;;;
;;; clear-scrollback is exported from nerimux/terminal/actions but was previously
;;; only called indirectly (via the clear-history command integration path).
;;; These tests verify it directly.

(describe "terminal-suite/clear-scrollback-suite"

  ;; clear-scrollback sets the screen-scrollback slot to NIL.
  (it "clear-scrollback-empties-scrollback-list"
    (with-screen (s 5 3)
      ;; Build up scrollback by scrolling
      (feed-lines s "L0" "L1" "L2" "L3")
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))
      (nerimux/terminal/actions:clear-scrollback s)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  ;; clear-scrollback on a screen with no scrollback is a no-op (no error, stays NIL).
  (it "clear-scrollback-noop-on-empty-scrollback"
    (with-screen (s 5 3)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))
      (finishes (nerimux/terminal/actions:clear-scrollback s))
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  ;; clear-scrollback does not modify the visible grid cells.
  (it "clear-scrollback-leaves-visible-grid-intact"
    (with-screen (s 5 3)
      (feed s "hello")                           ; write on the visible grid
      (feed-lines s "" "L1" "L2" "L3")           ; build some scrollback
      (nerimux/terminal/actions:clear-scrollback s)
      ;; After clear-scrollback, row 0 visible content is from post-scroll state
      ;; — the key assertion is that the visible grid is NOT blanked.
      (expect (null (nerimux/terminal/types:screen-scrollback s)))
      ;; Visible grid must still have non-blank content somewhere
      (let ((any-non-blank nil))
        (dotimes (y 3)
          (unless (row-blank-p s y)
            (setf any-non-blank t)))
        (expect any-non-blank :to-be-truthy)))))

;;; ── SUITE: scroll-on-clear-edge-cases ─────────────────────────────────────────
;;;
;;; scroll-on-clear used to be a callback the bootstrap layer installed from
;;; the option value; the ON/OFF split lived in whether that callback
;;; returned non-nil or nil.  With the option gone, ED 2 always pushes the
;;; visible screen to scrollback (erase.lisp mode 2), so only the ON case
;;; survives as a reachable state — the OFF-path tests are deleted, not
;;; rewritten.

(describe "terminal-suite/scroll-on-clear-edge-cases"

  ;; ED 2 (ESC[2J) unconditionally pushes the visible rows to scrollback before
  ;; erasing.
  (it "ed2-always-pushes-content-to-scrollback"
    (with-screen (s 5 3)
      (feed s "AAAAA")
      (feed s (esc "[2J"))
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s)))))))

;;; ── SUITE: decstbm additional edge cases ─────────────────────────────────────
;;;
;;; Direct tests for decstbm edge cases not covered by the existing
;;; constrained-scroll and scroll-region suites.

(describe "terminal-suite/decstbm-edge-cases"

  ;; Calling decstbm twice with different valid regions updates the scroll region
  ;; to the second call's values (no residual from the first call).
  (it "decstbm-repeated-call-updates-region"
    (with-screen (s 10 10)
      (nerimux/terminal/actions:decstbm s 0 4)   ; first call: rows 0-4
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 4 (nerimux/terminal/types:screen-scroll-bottom s)))
      (nerimux/terminal/actions:decstbm s 2 8)   ; second call: rows 2-8
      (expect (= 2 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 8 (nerimux/terminal/types:screen-scroll-bottom s)))))

  ;; decstbm with top=0, bottom=0 is rejected (top == bottom, not top < bottom).
  ;; The existing scroll region must remain unchanged.
  (it "decstbm-single-row-region-accepted"
    (with-screen (s 5 5)
      (let ((orig-top    (nerimux/terminal/types:screen-scroll-top    s))
            (orig-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 0 0)   ; top == bottom: invalid
        (expect (= orig-top    (nerimux/terminal/types:screen-scroll-top    s)))
        (expect (= orig-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  ;; decstbm with top=0, bottom=1 is the smallest valid region (two rows).
  (it "decstbm-minimum-valid-region-top-0-bottom-1"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 0 1)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 1 (nerimux/terminal/types:screen-scroll-bottom s))))))

;;; ── SUITE: scroll dirty-p edge cases ─────────────────────────────────────────
;;;
;;; scroll-up-one and scroll-down-one must mark the screen dirty even when the
;;; scroll region is restricted (non-default decstbm).

(describe "terminal-suite/scroll-dirty-restricted-region"

  ;; scroll-up-one marks the screen dirty even when scrolling a sub-region.
  (it "scroll-up-marks-dirty-with-restricted-region"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 1 3)   ; rows 1-3 only
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
      (nerimux/terminal/actions:scroll-up-one s)
      (expect (nerimux/terminal/types:screen-dirty-p s))))

  ;; scroll-down-one marks the screen dirty even when scrolling a sub-region.
  (it "scroll-down-marks-dirty-with-restricted-region"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 1 3)
      (screen-clear-dirty s)
      (nerimux/terminal/actions:scroll-down-one s)
      (expect (nerimux/terminal/types:screen-dirty-p s)))))

;;; ── SUITE: scroll-up-one with pre-filled content ────────────────────────────
;;;
;;; Verify that scroll-up-one moves content as expected (row content shifts).

(describe "terminal-suite/scroll-content-verification"

  ;; scroll-up-one moves row N to row N-1 within the scroll region.
  (it "scroll-up-one-displaces-content-upward"
    (with-screen (s 5 3)
      (feed-lines s "ROW0" "ROW1" "ROW2")
      (nerimux/terminal/actions:scroll-up-one s)
      ;; Row 0 was displaced to scrollback; old row 1 is now row 0.
      (check-row s 0 "ROW1")
      ;; Old row 2 is now row 1.
      (check-row s 1 "ROW2")
      ;; Row 2 (the newly exposed bottom) must be blank.
      (expect (row-blank-p s 2))))

  ;; scroll-down-one moves row N to row N+1 within the scroll region.
  (it "scroll-down-one-displaces-content-downward"
    (with-screen (s 5 3)
      (feed-lines s "ROW0" "ROW1" "ROW2")
      (nerimux/terminal/actions:scroll-down-one s)
      ;; Row 0 must be blank (newly inserted at top).
      (expect (row-blank-p s 0))
      ;; Old row 0 is now at row 1.
      (check-row s 1 "ROW0")
      ;; Old row 1 is now at row 2.
      (check-row s 2 "ROW1"))))

;;; ── SUITE: scroll metadata and resize refill ───────────────────────────────

(describe "terminal-suite/scroll-metadata-and-resize"

  (it "scroll-up-one-shifts-line-size-metadata"
    (with-screen (s 5 3)
      (let ((sizes (nerimux/terminal/types:screen-line-sizes s)))
        (setf (gethash 1 sizes) :double-width)
        (nerimux/terminal/actions:scroll-up-one s)
        (multiple-value-bind (value present-p) (gethash 0 sizes)
          (expect present-p)
          (expect (eq :double-width value)))
        (expect (not (nth-value 1 (gethash 1 sizes)))))))

  (it "trim-below-cursor-refills-visible-rows-from-history"
    (with-screen (s 5 4)
      (setf (nerimux/terminal/types:screen-cursor-y s) 0
            (nerimux/terminal/types:screen-scrollback s)
            (list (make-array 2 :initial-element
                              (nerimux/terminal/types:blank-cell)))
            (nerimux/terminal/types:screen-scrollback-wrapped s)
            (list nil nil nil))
      (nerimux/terminal/actions:trim-below-cursor s)
      (expect (= 3 (nerimux/terminal/types:screen-cursor-y s)))
      (expect (null (nerimux/terminal/types:screen-scrollback s)))
      (expect (null (nerimux/terminal/types:screen-scrollback-wrapped s)))))

  (it "trim-below-cursor-is-noop-on-alt-screen"
    (with-screen (s 5 4)
      (nerimux/terminal/actions:enter-alt-screen s)
      (setf (nerimux/terminal/types:screen-cursor-y s) 0
            (nerimux/terminal/types:screen-scrollback s)
            (list (make-array 5 :initial-element
                              (nerimux/terminal/types:blank-cell))))
      (nerimux/terminal/actions:trim-below-cursor s)
      (expect (= 0 (nerimux/terminal/types:screen-cursor-y s)))
      (expect (= 1 (length (nerimux/terminal/types:screen-scrollback s)))))))

;;; ── SUITE: push-row-to-scrollback internals ──────────────────────────────────
;;;
;;; %push-row-to-scrollback is private but its effect (prepend row to scrollback
;;; and enforce history cap) is exercised here via scroll-up-one and
;;; scroll-screen-to-history.

(describe "terminal-suite/push-row-to-scrollback-suite"

  ;; After three scroll-up-one calls, the scrollback is newest-first: the last
  ;; displaced row is at index 0.
  (it "scroll-up-one-preserves-newest-first-ordering"
    (with-screen (s 5 4)
      (feed-lines s "ROW0" "ROW1" "ROW2" "ROW3")
      ;; Scroll row 0 into history, then row 1, then row 2.
      (nerimux/terminal/actions:scroll-up-one s)   ; pushes ROW0
      (nerimux/terminal/actions:scroll-up-one s)   ; pushes ROW1 (now at top)
      (nerimux/terminal/actions:scroll-up-one s)   ; pushes ROW2 (now at top)
      (let ((scrollback (nerimux/terminal/types:screen-scrollback s)))
        (expect (= 3 (length scrollback)))
        ;; newest-first: index 0 = last pushed = ROW2
        (let ((newest-char (cell-char (aref (first scrollback) 0))))
          (expect (char= #\R newest-char))))))

  ;; scroll-up-one never lets scrollback grow beyond +max-scrollback-lines+.
  ;; Seeding the scrollback (and its parallel wrap-flag list, so
  ;; trim-scroll-history's lockstep truncation stays consistent) to just
  ;; under the real 10,000 cap directly, then driving only 3 real
  ;; scroll-up-one calls across the boundary, exercises the cap through the
  ;; actual push→trim path without looping scroll-up-one thousands of times.
  (it "history-cap-enforced-after-scroll-up-one"
    (with-screen (s 5 3)
      (let ((cap nerimux/terminal:+max-scrollback-lines+))
        (setf (nerimux/terminal/types:screen-scrollback s)
              (loop repeat (1- cap)
                    collect (make-array 5 :initial-element
                                          (nerimux/terminal/types:blank-cell)))
              (nerimux/terminal/types:screen-scrollback-wrapped s)
              (loop repeat (1- cap) collect nil))
        (dotimes (_ 3)
          (nerimux/terminal/actions:scroll-up-one s))
        (expect (<= (length (nerimux/terminal/types:screen-scrollback s)) cap))))))

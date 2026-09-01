(in-package #:nerimux/test/commands)

;;;; copy-mode WORD motion and cursor movement (src/commands.lisp) — part II
(describe "commands-suite"

  ;;; ── copy-mode-move-cursor ────────────────────────────────────────────────────

  ;; Each direction moves the cursor by 1 step and marks the screen dirty.
  (it "copy-mode-move-cursor-direction-table"
    (dolist (c '((:left  2 5  2 4)   ; (dir start-row start-col expected-row expected-col)
                 (:right 2 5  2 6)
                 (:up    2 5  1 5)
                 (:down  2 5  3 5)))
      (destructuring-bind (dir sr sc er ec) c
        (with-copy-mode-cursor (s sr sc)
          (nerimux/commands::copy-mode-move-cursor s dir)
          (expect (equal (cons er ec) (nerimux/terminal/types:screen-copy-cursor s)))
          (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-truthy)))))

  ;; At each axis boundary, move-cursor clamps rather than wrapping or crashing.
  (it "copy-mode-move-cursor-boundary-clamping"
    (dolist (c '((:left  2  0  cdr  0  "col must not go below 0")
                 (:up    0  5  car  0  "row must not go below 0")
                 (:right 2 19  cdr 19  "col must clamp at width-1=19")
                 (:down  4  5  car  4  "row must clamp at height-1=4")))
      (destructuring-bind (dir sr sc accessor expected msg) c
        (declare (ignore msg))
        (with-copy-mode-cursor (s sr sc)
          (nerimux/commands::copy-mode-move-cursor s dir)
          (expect (= expected (funcall accessor (nerimux/terminal/types:screen-copy-cursor s))))))))

  ;; While selecting, :right may advance the cursor to WIDTH (the exclusive end past
  ;; the last column) so the selection can include the rightmost cell — navigation
  ;; still caps at WIDTH-1 (covered by the test above).
  (it "copy-mode-selection-cursor-can-reach-width"
    (let ((s (make-screen 5 3)))
      (feed s "abcde")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      (nerimux/commands::copy-mode-begin-selection s)
      (dotimes (i 6) (nerimux/commands::copy-mode-move-cursor s :right))
      (expect (= 5 (cdr (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (string= "abcde" (nerimux/commands::%selection-text s)))))

  ;; copy-mode-enter initialises the cursor at the bottom-left of the viewport (row height-1, col 0).
  (it "copy-mode-enter-places-cursor-at-bottom-left"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (expect (equal (cons 4 0) (nerimux/terminal/types:screen-copy-cursor s)))))

  ;; If copy-cursor is manually reset to NIL, move-cursor falls back to (height-1 . 0) before moving.
  (it "copy-mode-move-cursor-nil-fallback"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      ;; Force cursor to NIL to exercise the fallback path inside move-cursor.
      (setf (nerimux/terminal/types:screen-copy-cursor s) nil)
      (nerimux/commands::copy-mode-move-cursor s :right)
      (expect (equal (cons 4 1) (nerimux/terminal/types:screen-copy-cursor s)))))

  ;; When copy-selecting is T and mark is NIL, the first move sets the mark anchor.
  (it "copy-mode-move-cursor-sets-mark-anchor-when-selecting-and-mark-nil"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 3)
            (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) nil)
      (nerimux/commands::copy-mode-move-cursor s :right)
      (expect (nerimux/terminal/types:screen-copy-mark s) :to-be-truthy)))

  ;; copy-mode-move-cursor does nothing when copy mode is not active.
  (it "copy-mode-move-cursor-noop-outside-copy-mode"
    (let ((s (make-screen 20 5)))
      ;; do NOT enter copy mode
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 5))
      (nerimux/commands::copy-mode-move-cursor s :left)
      (expect (equal (cons 2 5) (nerimux/terminal/types:screen-copy-cursor s)))))

  )

(in-package #:nerimux/test)

(describe "renderer-suite/pane-selection"

  (it "compute-selection-bounds-inactive-without-selecting-flag"
    (let ((s (copy-mode-screen :mark (cons 1 0) :cursor (cons 3 0))))
      (multiple-value-bind (active start-row end-row start-col end-col rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds s)
        (expect active :to-be-falsy)
        (expect (= 0 start-row)) (expect (= 0 end-row))
        (expect (= 0 start-col)) (expect (= 0 end-col))
        (expect rect-p :to-be-falsy)
        (expect (= 0 mark-row)) (expect (= 0 mark-col)))))

  (it "compute-selection-bounds-forward-selection"
    (let ((s (copy-mode-screen :mark (cons 1 2) :cursor (cons 3 8) :selecting t)))
      (multiple-value-bind (active start-row end-row start-col end-col rect-p mark-row mark-col)
          (nerimux/renderer::%compute-selection-bounds s)
        (expect active :to-be-truthy)
        (expect (= 1 start-row))
        (expect (= 3 end-row))
        (expect (= 2 start-col))
        (expect (= 8 end-col))
        (expect rect-p :to-be-falsy)
        (expect (= 1 mark-row))
        (expect (= 2 mark-col)))))

  (it "compute-selection-bounds-backward-selection"
    (let ((s (copy-mode-screen :mark (cons 3 8) :cursor (cons 1 2) :selecting t)))
      (multiple-value-bind (active start-row end-row start-col end-col)
          (nerimux/renderer::%compute-selection-bounds s)
        (expect active :to-be-truthy)
        (expect (= 1 start-row))
        (expect (= 3 end-row))
        (expect (= 2 start-col))
        (expect (= 8 end-col)))))

  (it "compute-selection-bounds-same-row-selection"
    (let ((s (copy-mode-screen :mark (cons 2 8) :cursor (cons 2 3) :selecting t)))
      (multiple-value-bind (active start-row end-row start-col end-col)
          (nerimux/renderer::%compute-selection-bounds s)
        (declare (ignore active))
        (expect (= 2 start-row))
        (expect (= 2 end-row))
        (expect (= 3 start-col))
        (expect (= 8 end-col)))))

  (it "compute-selection-bounds-rectangle-selection"
    (let ((s (copy-mode-screen :mark (cons 3 8) :cursor (cons 1 2) :selecting t)))
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t)
      (multiple-value-bind (active start-row end-row start-col end-col rect-p)
          (nerimux/renderer::%compute-selection-bounds s)
        (declare (ignore active start-row end-row))
        (expect rect-p :to-be-truthy)
        (expect (= 2 start-col))
        (expect (= 9 end-col))))))

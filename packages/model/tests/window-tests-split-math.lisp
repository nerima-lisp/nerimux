(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "grow-first-p-table"
    (dolist (row '((:first  :right t   ":first grows on :right")
                   (:first  :down  t   ":first grows on :down")
                   (:first  :left  nil ":first does not grow on :left")
                   (:first  :up    nil ":first does not grow on :up")
                   (:second :left  t   ":second grows on :left")
                   (:second :up    t   ":second grows on :up")
                   (:second :right nil ":second does not grow on :right")
                   (:second :down  nil ":second does not grow on :down")))
      (destructuring-bind (side direction expected desc) row
        (declare (ignore desc))
        (if expected
            (expect (nerimux/window::%grow-first-p side direction) :to-be-truthy)
            (expect (nerimux/window::%grow-first-p side direction) :to-be-falsy)))))


  (it "split-child-geometry-table"
    (dolist (row '((:h 41 20 21 0  20 20)
                   (:v 80 25 0  13 80 12)))
      (destructuring-bind (orient w h ex ey ew eh) row
        (let ((p (make-pane :id 1 :x 0 :y 0 :width w :height h :fd -1 :pid -1
                            :screen (make-screen w h))))
          (multiple-value-bind (px py pw ph)
              (nerimux/layout::split-child-geometry p orient)
            (expect (eql ex px))
            (expect (eql ey py))
            (expect (eql ew pw))
            (expect (eql eh ph)))))))


  (it "new-split-ratio-table"
    (dolist (row '((:h 80 1/2  5 t  45/80 "grow: cur=40, +5 → 45/80")
                   (:h 10 1/2 10 t  nil   "blocked: new=15 > max=8 → NIL")
                   (:v 20 1/2  3 nil 7/20  "shrink: cur=10, -3 → 7/20")))
      (destructuring-bind (orient avail ratio delta grow-first expected desc) row
        (declare (ignore desc))
        (expect (equal expected
                   (nerimux/window::%new-split-ratio orient avail ratio delta grow-first))))))


  (it "requested-cells-from-hint-table"
    (dolist (row '((20   80 :h 20 "positive integer hint passes through unchanged")
                   (0    80 :h 40 "zero integer hint falls back to half of avail")
                   (-5   80 :h 40 "negative integer hint falls back to half of avail")
                   (0.25 80 :h 20 "real hint in (0,1) scales avail proportionally")
                   (0.3  80 :h 24 "real hint 0.3 scales and rounds to nearest cell")
                   (1.0  80 :h 40 "real hint >= 1.0 falls back to half of avail")
                   (0.0  80 :h 40 "real hint <= 0.0 falls back to half of avail")
                   (nil  80 :h 40 "non-numeric hint falls back to half of avail")))
      (destructuring-bind (hint avail orient expected desc) row
        (declare (ignore desc))
        (expect (eql expected
                 (nerimux/window::%requested-cells-from-hint hint avail orient))))))


  (it "ratio-from-size-hint-clamps-to-axis-floor"
    (expect (= 1/5 (nerimux/window::%ratio-from-size-hint 1 10 :h)))
    (expect (= 4/5 (nerimux/window::%ratio-from-size-hint 9 10 :h))))

  (it "ratio-from-size-hint-mid-range-passes-through"
    (expect (= 1/4 (nerimux/window::%ratio-from-size-hint 20 80 :h))))


  (it "split-fits-p-table"
    (dolist (row '((:h 5  3  t   "h exactly-minimum width of 5 → fits")
                   (:v 5  3  t   "v exactly-minimum height of 3 → fits")
                   (:h 4  5  nil "h width 4 < 5 → does not fit")
                   (:v 5  2  nil "v height 2 < 3 → does not fit")))
      (destructuring-bind (orient w h expected desc) row
        (declare (ignore desc))
        (let ((p (make-pane :id 1 :fd -1 :pid -1 :width w :height h
                            :screen (make-screen w h))))
          (if expected
              (expect (nerimux/window::%split-fits-p p orient) :to-be-truthy)
              (expect (nerimux/window::%split-fits-p p orient) :to-be-falsy))))))

  )

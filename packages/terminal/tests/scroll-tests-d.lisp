(in-package #:nerimux/test/terminal)

(describe "terminal-suite/clear-scrollback-suite"

  (it "clear-scrollback-empties-scrollback-list"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2" "L3")
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))
      (nerimux/terminal/actions:clear-scrollback s)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  (it "clear-scrollback-noop-on-empty-scrollback"
    (with-screen (s 5 3)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))
      (finishes (nerimux/terminal/actions:clear-scrollback s))
      (expect (null (nerimux/terminal/types:screen-scrollback s)))))

  (it "clear-scrollback-leaves-visible-grid-intact"
    (with-screen (s 5 3)
      (feed s "hello")                           ; write on the visible grid
      (feed-lines s "" "L1" "L2" "L3")           ; build some scrollback
      (nerimux/terminal/actions:clear-scrollback s)
      (expect (null (nerimux/terminal/types:screen-scrollback s)))
      (let ((any-non-blank nil))
        (dotimes (y 3)
          (unless (row-blank-p s y)
            (setf any-non-blank t)))
        (expect any-non-blank :to-be-truthy)))))

(describe "terminal-suite/scroll-on-clear-edge-cases"

  (it "ed2-always-pushes-content-to-scrollback"
    (with-screen (s 5 3)
      (feed s "AAAAA")
      (feed s (esc "[2J"))
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s)))))))

(describe "terminal-suite/decstbm-edge-cases"

  (it "decstbm-repeated-call-updates-region"
    (with-screen (s 10 10)
      (nerimux/terminal/actions:decstbm s 0 4)   ; first call: rows 0-4
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 4 (nerimux/terminal/types:screen-scroll-bottom s)))
      (nerimux/terminal/actions:decstbm s 2 8)   ; second call: rows 2-8
      (expect (= 2 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 8 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "decstbm-single-row-region-accepted"
    (with-screen (s 5 5)
      (let ((orig-top    (nerimux/terminal/types:screen-scroll-top    s))
            (orig-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 0 0)   ; top == bottom: invalid
        (expect (= orig-top    (nerimux/terminal/types:screen-scroll-top    s)))
        (expect (= orig-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  (it "decstbm-minimum-valid-region-top-0-bottom-1"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 0 1)
      (expect (= 0 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 1 (nerimux/terminal/types:screen-scroll-bottom s))))))

(describe "terminal-suite/scroll-dirty-restricted-region"

  (it "scroll-up-marks-dirty-with-restricted-region"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 1 3)   ; rows 1-3 only
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
      (nerimux/terminal/actions:scroll-up-one s)
      (expect (nerimux/terminal/types:screen-dirty-p s))))

  (it "scroll-down-marks-dirty-with-restricted-region"
    (with-screen (s 5 5)
      (nerimux/terminal/actions:decstbm s 1 3)
      (screen-clear-dirty s)
      (nerimux/terminal/actions:scroll-down-one s)
      (expect (nerimux/terminal/types:screen-dirty-p s)))))

(describe "terminal-suite/scroll-content-verification"

  (it "scroll-up-one-displaces-content-upward"
    (with-screen (s 5 3)
      (feed-lines s "ROW0" "ROW1" "ROW2")
      (nerimux/terminal/actions:scroll-up-one s)
      (check-row s 0 "ROW1")
      (check-row s 1 "ROW2")
      (expect (row-blank-p s 2))))

  (it "scroll-down-one-displaces-content-downward"
    (with-screen (s 5 3)
      (feed-lines s "ROW0" "ROW1" "ROW2")
      (nerimux/terminal/actions:scroll-down-one s)
      (expect (row-blank-p s 0))
      (check-row s 1 "ROW0")
      (check-row s 2 "ROW1"))))

(describe "terminal-suite/scroll-metadata-and-resize"
          (it "scroll-up-one-shifts-line-size-metadata"
              (with-screen (s 5 3)
                           (let ((sizes
                                  (nerimux/terminal/types:screen-line-sizes s)))
                             (setf (gethash 1 sizes) :double-width)
                             (nerimux/terminal/actions:scroll-up-one s)
                             (multiple-value-bind (value present-p) 
                                 (gethash 0 sizes)
                               (expect present-p)
                               (expect (eq :double-width value)))
                             (expect (not (nth-value 1 (gethash 1 sizes)))))))
          (it "trim-below-cursor-refills-visible-rows-from-history"
              (with-screen (s 5 4)
                           (setf (nerimux/terminal/types:screen-cursor-y s) 0
                                 (nerimux/terminal/types:screen-scrollback s) (list
                                                                               (make-array
                                                                                2
                                                                                :initial-element
                                                                                (nerimux/terminal/types:blank-cell)))
                                 (nerimux/terminal/types:screen-scrollback-wrapped
                                  s) (list nil nil nil))
                           (nerimux/terminal/actions:trim-below-cursor s)
                           (expect
                            (= 3 (nerimux/terminal/types:screen-cursor-y s)))
                           (expect
                            (null (nerimux/terminal/types:screen-scrollback s)))
                           (expect
                            (null
                             (nerimux/terminal/types:screen-scrollback-wrapped
                              s)))))
          (it "trim-below-cursor-is-noop-on-alt-screen"
              (with-screen (s 5 4)
                           (nerimux/terminal/actions:enter-alt-screen s)
                           (setf (nerimux/terminal/types:screen-cursor-y s) 0
                                 (nerimux/terminal/types:screen-scrollback s) (list
                                                                               (make-array
                                                                                5
                                                                                :initial-element
                                                                                (nerimux/terminal/types:blank-cell))))
                           (nerimux/terminal/actions:trim-below-cursor s)
                           (expect
                            (= 0 (nerimux/terminal/types:screen-cursor-y s)))
                           (expect
                            (= 1
                               (length
                                (nerimux/terminal/types:screen-scrollback s)))))))

(describe "terminal-suite/push-row-to-scrollback-suite"

  (it "scroll-up-one-preserves-newest-first-ordering"
    (with-screen (s 5 4)
      (feed-lines s "ROW0" "ROW1" "ROW2" "ROW3")
      (nerimux/terminal/actions:scroll-up-one s)   ; pushes ROW0
      (nerimux/terminal/actions:scroll-up-one s)   ; pushes ROW1 (now at top)
      (nerimux/terminal/actions:scroll-up-one s)   ; pushes ROW2 (now at top)
      (let ((scrollback (nerimux/terminal/types:screen-scrollback s)))
        (expect (= 3 (length scrollback)))
        (let ((newest-char (cell-char (aref (first scrollback) 0))))
          (expect (char= #\R newest-char))))))

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

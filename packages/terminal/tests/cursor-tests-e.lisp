(in-package #:nerimux/test/terminal)

(describe "terminal-suite/multi-stop-tab-navigation"

  (defun %install-tab-stops (screen &rest columns)
    "Clear SCREEN's tab stops, then move the cursor to each column in COLUMNS and
   call set-tab-stop (HTS), installing a clean multi-entry custom tab-stop list
   with exactly the given columns (set-tab-stop otherwise merges new stops into
   whatever list — including the expanded :default grid — is already present)."
    (nerimux/terminal/actions:clear-tab-stops screen 3)   ; TBC 3: clear ALL stops
    (dolist (col columns)
      (setf (nerimux/terminal/types:screen-cursor-x screen) col)
      (nerimux/terminal/actions:set-tab-stop screen)))

  (it "cursor-ht-with-three-custom-stops-advances-in-order"
    (with-screen (s 40 5)
      (%install-tab-stops s 3 10 15)
      (setf (nerimux/terminal/types:screen-cursor-x s) 0)
      (nerimux/terminal/actions:cursor-ht s)
      (expect (= 3 (screen-cursor-x s)))
      (nerimux/terminal/actions:cursor-ht s)
      (expect (= 10 (screen-cursor-x s)))
      (nerimux/terminal/actions:cursor-ht s)
      (expect (= 15 (screen-cursor-x s)))))

  (it "cursor-ht-past-last-custom-stop-clamps-to-width-minus-one"
    (with-screen (s 20 5)
      (%install-tab-stops s 3 10)
      (setf (nerimux/terminal/types:screen-cursor-x s) 10)
      (nerimux/terminal/actions:cursor-ht s)
      (expect (= 19 (screen-cursor-x s)))))

  (it "cursor-cbt-with-three-custom-stops-moves-back-in-order"
    (with-screen (s 40 5)
      (%install-tab-stops s 3 10 15)
      (setf (nerimux/terminal/types:screen-cursor-x s) 18)
      (nerimux/terminal/actions:cursor-cbt s 1)
      (expect (= 15 (screen-cursor-x s)))
      (nerimux/terminal/actions:cursor-cbt s 1)
      (expect (= 10 (screen-cursor-x s)))
      (nerimux/terminal/actions:cursor-cbt s 1)
      (expect (= 3 (screen-cursor-x s)))))

  (it "cursor-cbt-before-first-custom-stop-clamps-to-zero"
    (with-screen (s 40 5)
      (%install-tab-stops s 10 20)
      (setf (nerimux/terminal/types:screen-cursor-x s) 5)
      (nerimux/terminal/actions:cursor-cbt s 1)
      (expect (= 0 (screen-cursor-x s)))))

  (it "materialize-tab-stops-returns-custom-list-unchanged"
    (with-screen (s 40 5)
      (%install-tab-stops s 5 12)
      (let ((stops (nerimux/terminal/actions::%materialize-tab-stops s)))
        (expect (equal '(5 12) stops)))))

  (it "materialize-tab-stops-expands-default-sentinel"
    (with-screen (s 20 5)
      (let ((stops (nerimux/terminal/actions::%materialize-tab-stops s)))
        (expect (equal '(8 16) stops))))))

(describe "terminal-suite/cursor-cr-bs-table-suite"

  (it "cursor-cr-from-various-columns-table"
    (dolist (row '((0 0 "col 0 stays at 0")
                   (5 0 "col 5 resets to 0")
                   (9 0 "last column resets to 0")))
      (destructuring-bind (start expected desc) row
        (declare (ignore desc))
        (with-cursor-at (s 10 5 start)
          (nerimux/terminal/actions:cursor-cr s)
          (expect (= expected (screen-cursor-x s)))))))

  (it "cursor-bs-from-various-columns-table"
    (dolist (row '((0 0 "col 0 stays at 0 (no-op)")
                   (1 0 "col 1 moves to 0")
                   (5 4 "col 5 moves to 4")
                   (9 8 "last column moves to 8")))
      (destructuring-bind (start expected desc) row
        (declare (ignore desc))
        (with-cursor-at (s 10 5 start)
          (nerimux/terminal/actions:cursor-bs s)
          (expect (= expected (screen-cursor-x s))))))))

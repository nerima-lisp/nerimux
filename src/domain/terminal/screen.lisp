(in-package #:nerimux/terminal/types)

;;;; Screen construction and grid access.
;;;;
;;;; The screen data definition lives in screen-data.lisp.  Mutation helpers
;;;; that operate on screen state live in the adjacent screen-* modules.

(defun %make-blank-cells (cell-count)
  "Allocate a simple vector of CELL-COUNT blank cells.

Each call to BLANK-CELL allocates a fresh struct; MAKE-ARRAY
:initial-element cannot be used because mutations would then be shared by all
positions."
  (make-array cell-count :initial-contents (loop repeat cell-count collect (blank-cell))))

(defun make-screen (width height)
  "Create a blank WIDTH x HEIGHT screen with cursor at origin.

The mutex is allocated here, rather than in the data definition, so loading
the declarative screen state has no side effects.  The parser continuation is
wired after all packages have loaded."
  (let ((screen (%make-screen :width         width
                               :height        height
                               :cells         (%make-blank-cells (* width height))
                               :scroll-bottom (1- height)
                               :lock          (make-lock :name "screen"))))
    (setf (screen-parser screen)
          (lambda (s byte) (nerimux/terminal/parser:ground-state s byte)))
    screen))

(defun screen-cell (screen x y)
  "Return the cell at column X, row Y."
  (aref (screen-cells screen)
        (+ (* y (screen-width screen)) x)))

(defun (setf screen-cell) (cell screen x y)
  "Store CELL at column X, row Y in SCREEN's grid.

Dirty-marking is the responsibility of the action layer; this setter is a
pure grid accessor."
  (setf (aref (screen-cells screen)
              (+ (* y (screen-width screen)) x))
        cell))

;;; screen-clear-dirty, screen-consume-bell, and reset-sgr-pen are defined in
;;; screen-logic.lisp (loaded immediately after this file).

(in-package #:nerimux/terminal/types)

(defun %copy-overlapping-cells (screen old-cells old-width copy-cols copy-rows)
  "Copy the top-left COPY-COLS x COPY-ROWS rectangle from OLD-CELLS (a raw
   vector with OLD-WIDTH stride) into SCREEN's freshly installed grid."
  (dotimes (y copy-rows)
    (dotimes (x copy-cols)
      (setf (screen-cell screen x y) (aref old-cells (+ (* y old-width) x))))))

(defun screen-resize (screen new-width new-height)
  "Resize SCREEN to NEW-WIDTH x NEW-HEIGHT in place, preserving the
   overlapping top-left rectangle of content.  Resets the scroll region to
   the full new height and clamps the cursor into bounds.

   Alt-cells geometry is not resized; callers that need alt-screen consistency
   should exit alt-screen mode before resizing.

   Callers that share the screen with a reader thread must hold SCREEN's
   lock; this function does no locking of its own."
  (when (and (= new-width  (screen-width  screen))
             (= new-height (screen-height screen)))
    (return-from screen-resize screen))
  (let* ((old-width  (screen-width  screen))
         (old-height (screen-height screen))
         (old-cells  (screen-cells  screen)))
    (setf (screen-cells  screen) (%make-blank-cells (* new-width new-height))
          (screen-width  screen) new-width
          (screen-height screen) new-height)
    (%copy-overlapping-cells screen old-cells old-width
                             (min old-width new-width) (min old-height new-height))
    (setf (screen-scroll-top    screen) 0
          (screen-scroll-bottom screen) (1- new-height)
          (screen-cursor-x      screen) (clamp (screen-cursor-x screen) 0 (1- new-width))
          (screen-cursor-y      screen) (clamp (screen-cursor-y screen) 0 (1- new-height))
          (screen-dirty-p       screen) t)
    (%clear-all-line-wrapped screen)
    screen))

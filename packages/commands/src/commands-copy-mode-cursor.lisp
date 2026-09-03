(in-package #:nerimux/commands)

(defun %scroll-up-one-line (screen row col max-offset)
  "Move cursor up one line in copy-mode viewport for SCREEN.
   ROW/COL is the current cursor position; MAX-OFFSET is the scrollback length.
   When the cursor is at row 0 and scrollback remains, scrolls the viewport
   back one line, keeping the cursor pinned at row 0.
   At the oldest scrollback line the call is a no-op."
  (let ((new-row (1- row)))
    (cond
      ((>= new-row 0)
       (setf (screen-copy-cursor screen) (cons new-row col)))
      ((< (screen-copy-offset screen) max-offset)
       (incf (screen-copy-offset screen))
       (setf (screen-copy-cursor screen) (cons 0 col)))
      (t nil))))

(defun %scroll-down-one-line (screen row col h)
  "Move cursor down one line in copy-mode viewport for SCREEN.
   ROW/COL is the current cursor position; H is the viewport height.
   When the cursor is at row H-1 and offset > 0, scrolls the viewport
   forward one line, keeping the cursor pinned at row H-1.
   At the live view bottom the call is a no-op."
  (let ((new-row (1+ row)))
    (cond
      ((< new-row h)
       (setf (screen-copy-cursor screen) (cons new-row col)))
      ((> (screen-copy-offset screen) 0)
       (decf (screen-copy-offset screen))
       (setf (screen-copy-cursor screen) (cons (1- h) col)))
      (t nil))))

(defun %copy-mode-move-left (screen row col)
  (setf (screen-copy-cursor screen) (cons row (max 0 (1- col)))))

(defun %copy-mode-move-right (screen row col w selecting)
  (let ((right-bound (if selecting w (1- w))))
    (setf (screen-copy-cursor screen)
          (cons row (min right-bound (1+ col))))))

(defun %copy-mode-ensure-selection-mark (screen)
  (when (and (screen-copy-selecting screen) (null (screen-copy-mark screen)))
    (setf (screen-copy-mark screen) (screen-copy-cursor screen))))

(defun copy-mode-move-cursor (screen direction)
  "Move SCREEN's copy-mode cursor in DIRECTION (:left :right :up :down).
   Initializes the cursor to bottom-left of the viewport if not yet set.
   For :up/:down the cursor moves one line at a time; when it would leave
   the visible viewport (row < 0 or row >= height) the viewport offset is
   adjusted instead so the cursor stays at the top or bottom edge.
   Marks the screen dirty."
  (when (screen-copy-mode-p screen)
    (let* ((h (screen-height screen))
           (w (screen-width screen))
           (cur (or (screen-copy-cursor screen) (cons (1- h) 0)))
           (row (car cur))
           (col (cdr cur))
           (max-offset (length (screen-scrollback screen))))
      (ecase direction
        (:left (%copy-mode-move-left screen row col))
        (:right
         (%copy-mode-move-right screen row col w (screen-copy-selecting screen)))
        (:up (%scroll-up-one-line screen row col max-offset))
        (:down (%scroll-down-one-line screen row col h)))
      (%copy-mode-ensure-selection-mark screen)
      (setf (screen-dirty-p screen) t))))

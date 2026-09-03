(in-package #:nerimux/terminal/actions)

(defun enter-alt-screen (screen &key save-cursor-p)
  "Save the current grid and cursor x/y to the alt-screen slots, then install a
   fresh blank grid.  When SAVE-CURSOR-P is T (?1049h), also save the FULL cursor
   state (SGR attrs, charset, origin mode) via SAVE-CURSOR, which is what makes
   ?1049h equivalent to ?1047h plus ?1048h (DECSC).
   No-op when the alt screen is already active."
  (unless (screen-alt-cells screen)
    (when save-cursor-p (save-cursor screen))
    (setf (screen-alt-cells  screen) (copy-seq (screen-cells screen))
          (screen-alt-cursor-x screen) (screen-cursor-x screen)
          (screen-alt-cursor-y screen) (screen-cursor-y screen))
    (setf (screen-cells screen)
          (%make-blank-cells (* (screen-width screen) (screen-height screen))))
    (set-cursor screen 0 0)
    (%clear-all-line-wrapped screen)
    (setf (screen-dirty-p screen) t)))

(defun exit-alt-screen (screen &key restore-cursor-p)
  "Restore the saved primary grid and cursor from the alt-screen slots.
   When RESTORE-CURSOR-P is T (mode 1049), also restore the FULL cursor state
   (SGR attrs, charset, origin mode) via RESTORE-CURSOR — equivalent to ?1047l
   + ?1048l (DECRC).  Falls back to erase-display mode 2 when nothing was saved."
  (if (screen-alt-cells screen)
      (setf (screen-cells screen) (screen-alt-cells screen)
            (screen-cursor-x screen) (screen-alt-cursor-x screen)
            (screen-cursor-y screen) (screen-alt-cursor-y screen)
            (screen-alt-cells screen) nil)
      (erase-display screen 2))
  (when restore-cursor-p
    (restore-cursor screen))
  (%clear-all-line-wrapped screen)
  (setf (screen-dirty-p screen) t))

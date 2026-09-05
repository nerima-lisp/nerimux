(in-package #:nerimux/commands)

(defun copy-mode-enter (screen &key scroll-to-top exit-on-bottom)
  "Enter copy/scroll mode on SCREEN: freeze the viewport at the live position.
   The copy-mode cursor is placed at the bottom-left of the viewport so that
   the first navigation key moves it naturally upward toward older content.
   SCROLL-TO-TOP T pre-scrolls to the oldest scrollback content (copy-mode -u).
   EXIT-ON-BOTTOM T (copy-mode -e) auto-exits copy mode when the viewport is
   scrolled back down to the live bottom (offset 0)."
  (setf (screen-copy-mode-p        screen) t
        (screen-copy-mark          screen) nil
        (screen-copy-mark-offset   screen) 0
        (screen-copy-selecting     screen) nil
        (screen-copy-exit-on-bottom screen) (and exit-on-bottom t))
  (if scroll-to-top
      (let ((max-offset (length (screen-scrollback screen))))
        (setf (screen-copy-offset screen) max-offset
              (screen-copy-cursor screen) (cons 0 0)))
      (setf (screen-copy-offset screen) 0
            (screen-copy-cursor screen) (cons (1- (screen-height screen)) 0))))

(defun copy-mode-exit (screen)
  "Exit copy mode: resume live PTY output display."
  (setf (screen-copy-mode-p        screen) nil
        (screen-copy-offset         screen) 0
        (screen-copy-mark           screen) nil
        (screen-copy-mark-offset    screen) 0
        (screen-copy-cursor         screen) nil
        (screen-copy-selecting      screen) nil
        (screen-copy-line-selection-p screen) nil
        (screen-copy-rect-select-p  screen) nil
        (screen-copy-exit-on-bottom screen) nil
        (screen-copy-mode-entered-by-mouse-p screen) nil
        (screen-copy-search-index   screen) nil
        (screen-copy-search-total   screen) 0))

(defun %clamp-row-col (screen row col)
  "Return (cons clamped-row clamped-col) with row in [0, height-1] and col in [0, width-1]."
  (cons (max 0 (min (1- (screen-height screen)) row))
        (max 0 (min (1- (screen-width screen)) col))))

(defun %copy-mode-clamp-cursor (screen)
  "Clamp the copy-mode cursor row into [0, height-1] and col into [0, width-1].
   Called after the viewport offset changes so the cursor stays visible.
   Operates on the cursor cons directly; no-op when cursor is NIL."
  (let ((cursor (screen-copy-cursor screen)))
    (when cursor
      (setf (screen-copy-cursor screen) (%clamp-row-col screen
                                                        (car cursor)
                                                        (cdr cursor))))))

(defun copy-mode-scroll (screen delta)
  "Scroll SCREEN's viewport by DELTA lines (positive = older, negative = newer).
   The copy-mode cursor is clamped to remain within the visible viewport.
   This is the raw viewport-jump path used by Page-Up/Down, mouse wheel, g/G.
   Arrow-key and j/k navigation goes through COPY-MODE-MOVE-CURSOR instead."
  (when (screen-copy-mode-p screen)
    (let ((max-offset (length (screen-scrollback screen))))
      (setf (screen-copy-offset screen)
            (max 0 (min max-offset (+ (screen-copy-offset screen) delta))))
      (%copy-mode-clamp-cursor screen)
      (setf (screen-dirty-p screen) t)
      (when (and (screen-copy-exit-on-bottom screen)
                 (< delta 0)
                 (zerop (screen-copy-offset screen)))
        (copy-mode-exit screen)))))

(defun copy-mode-begin-selection (screen)
  "Begin a text selection at the current copy-mode cursor position."
  (when (screen-copy-mode-p screen)
    (let ((cur (or (screen-copy-cursor screen) (cons 0 0))))
      (setf (screen-copy-mark screen) cur
            (screen-copy-mark-offset screen) (screen-copy-offset screen)
            (screen-copy-cursor screen) cur
            (screen-copy-selecting screen) t
            (screen-dirty-p screen) t))))

(defun %reset-selection-fields (screen)
  "Clear all selection state fields on SCREEN (selecting, mark, line/rect flags) and
   mark dirty.  Does NOT clear the cursor — callers that need that do so separately."
  (setf (screen-copy-selecting screen) nil
        (screen-copy-mark screen) nil
        (screen-copy-mark-offset screen) 0
        (screen-copy-line-selection-p screen) nil
        (screen-copy-rect-select-p screen) nil
        (screen-dirty-p screen) t))

(defun copy-mode-cancel-selection (screen)
  "Cancel any active copy-mode selection."
  (setf (screen-copy-cursor screen) nil)
  (%reset-selection-fields screen))

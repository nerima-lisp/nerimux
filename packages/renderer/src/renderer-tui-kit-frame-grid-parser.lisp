(in-package #:nerimux/renderer)

(defun %frame-grid-clear-line (row col mode &optional style-row style)
  (case mode
    (1
      (fill row #\Space :start 0 :end (min (1+ col) (length row)))
      (when style-row
        (fill style-row style :start 0 :end (min (1+ col) (length style-row)))))
    (2
      (fill row #\Space)
      (when style-row
        (fill style-row style)))
    (otherwise
      (fill row #\Space :start (min col (length row)))
      (when style-row
        (fill style-row style :start (min col (length style-row)))))))

(defun %frame-grid-apply-csi (grid row
                                   col
                                   saved-row
                                   saved-col
                                   params
                                   final
                                   &optional
                                   style-grid
                                   current-style)
  "Apply one parsed CSI sequence to the cursor/erase state.

   STYLE-GRID and CURRENT-STYLE are optional: callers that only care about
   cursor movement (the direct unit tests below) omit them and get the
   original cursor-only behavior.  The updated style is always returned as
   a fifth value; callers not tracking style simply discard it."
  (let ((height (length grid))
        (width (length (aref grid 0)))
        (count (or (first params) 1))
        (style current-style))
    (cond
      ((or (char= final #\A) (char= final #\B))
       (let ((delta
              (if (plusp count)
                  count
                  1)))
         (if (char= final #\A)
             (decf row delta)
             (incf row delta))))
      ((or (char= final #\C) (char= final #\D))
       (let ((delta
              (if (plusp count)
                  count
                  1)))
         (if (char= final #\C)
             (incf col delta)
             (decf col delta))))
      ((char= final #\G)
       (setf col (1- (%frame-grid-param params 0 1))))
      ((char= final #\d)
       (setf row (1- (%frame-grid-param params 0 1))))
      ((or (char= final #\H) (char= final #\f))
       (setf row (1- (%frame-grid-param params 0 1))
             col (1- (%frame-grid-param params 1 1))))
      ((char= final #\J)
       (when (member (or (first params) 0) '(2 3))
         (%clear-frame-grid grid
                            style-grid
                            (%bce-style (or style (%default-style))))))
      ((char= final #\K)
       (%frame-grid-clear-line (aref grid (max 0 (min row (1- height))))
                               col
                               (or (first params) 0)
                               (and style-grid
                                    (aref style-grid
                                          (max 0 (min row (1- height)))))
                               (%bce-style (or style (%default-style)))))
      ((char= final #\m)
       (setf style (%frame-grid-apply-sgr (or style (%default-style)) params)))
      ((char= final #\s)
       (setf saved-row row
             saved-col col))
      ((char= final #\u)
       (setf row saved-row
             col saved-col)))
    (values (max 0 (min row (1- height)))
            (max 0 (min col width))
            saved-row
            saved-col
            style)))

(defun %frame-grid-put-char (grid row col character &optional style-grid style)
  "Write CHARACTER into GRID at (ROW, COL) and return the column the next
   character belongs at (0 signals a row wrap -- the caller advances ROW).

   A double-width CHARACTER (CJK, most emoji -- NERIMUX/TERMINAL/TYPES:
   CHAR-WIDTH, the same measure R6.9's %DISPLAY-WIDTH uses) advances the
   column by 2 instead of 1 and marks the cell to its right with
   +FRAME-GRID-CONTINUATION+. The previous single-column advance here
   under-consumed the grid by one column per wide character, so every
   character written after it in the row -- with no intervening MOVE-TO,
   e.g. a border glyph appended right after a padded label -- landed one
   grid column left of where the source ANSI text (already correctly
   %DISPLAY-CLIP/%DISPLAY-WIDTH laid out) placed it. A zero-width character
   (combining marks) keeps the one-column advance, because that class does
   not occupy a grid cell.

   STYLE-GRID/STYLE are optional: when supplied, STYLE is also recorded for
   the written cell and its continuation cell (R-style-preservation)."
  (let* ((height (length grid))
         (width (length (aref grid 0)))
         (char-width
          (if (= 2 (nerimux/terminal/types:char-width character))
              2
              1))
         (fits-p (<= (+ col char-width) width)))
    (when (and (<= 0 row) (< row height) (<= 0 col) (< col width))
      (setf (char (aref grid row) col) character)
      (when style-grid
        (setf (aref (aref style-grid row) col) (or style (%default-style))))
      (when (and fits-p (= char-width 2))
        (setf (char (aref grid row) (1+ col)) +frame-grid-continuation+)
        (when style-grid
          (setf (aref (aref style-grid row) (1+ col)) (or style
                                                          (%default-style))))))
    (let ((advance
           (if fits-p
               char-width
               1)))
      (if (< (+ col advance) width)
          (+ col advance)
          0))))

(defun %frame-grid-parse-csi (frame start
                                    grid
                                    row
                                    col
                                    saved-row
                                    saved-col
                                    &optional
                                    style-grid
                                    current-style)
  (let ((end start)
        (length (length frame)))
    (loop while (and (< end length)
                     (not
                      (<= (char-code #\@)
                          (char-code (char frame end))
                          (char-code #\~))))
          do (incf end))
    (if (= end length)
        (values length row col saved-row saved-col current-style)
        (multiple-value-bind (new-row new-col
                                      new-saved-row
                                      new-saved-col
                                      new-style) 
            (%frame-grid-apply-csi grid
                                   row
                                   col
                                   saved-row
                                   saved-col
                                   (%frame-grid-params (subseq frame start end))
                                   (char frame end)
                                   style-grid
                                   current-style)
          (values (1+ end)
                  new-row
                  new-col
                  new-saved-row
                  new-saved-col
                  new-style)))))

(defun %frame-grid-skip-osc (frame start)
  (let ((index start)
        (length (length frame)))
    (loop while (< index length)
          do (cond
               ((= (char-code (char frame index)) 7) (return (1+ index)))
               ((and (= (char-code (char frame index)) 27)
                     (< (1+ index) length)
                     (char= (char frame (1+ index)) #\\)) (return (+ index 2)))
               (t (incf index)))
          finally (return length))))

(defun %ansi-frame-grid (frame rows cols)
  "Parse FRAME's ANSI escape sequences into a ROWS x COLS character grid.

   Returns (VALUES CHARS-GRID STYLE-GRID): STYLE-GRID is a parallel grid of
   CL-TUI-KIT/CORE:STYLE objects tracking every CSI ... m (SGR) sequence
   seen while parsing (R-style-preservation).  Existing call sites that
   only use the primary value are unaffected."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (grid (%make-frame-grid rows cols))
         (style-grid (%make-frame-style-grid rows cols))
         (row 0)
         (col 0)
         (saved-row 0)
         (saved-col 0)
         (current-style (%default-style))
         (index 0)
         (length (length frame)))
    (loop while (< index length)
          do (let ((character (char frame index)))
               (cond
                 ((= (char-code character) 27)
                  (if (>= (1+ index) length)
                      (incf index)
                      (case (char frame (1+ index))
                        (#\[
                         (multiple-value-setq (index row
                                                     col
                                                     saved-row
                                                     saved-col
                                                     current-style) (%frame-grid-parse-csi
                                                                     frame
                                                                     (+ index 2)
                                                                     grid
                                                                     row
                                                                     col
                                                                     saved-row
                                                                     saved-col
                                                                     style-grid
                                                                     current-style)))
                        (#\]
                         (setf index (%frame-grid-skip-osc frame (+ index 2))))
                        (otherwise (incf index 2)))))
                 ((char= character #\Newline)
                   (setf col 0
                         row (min (1+ row) (1- rows)))
                   (incf index))
                 ((char= character #\Return)
                   (setf col 0)
                   (incf index))
                 ((char= character #\Backspace)
                   (setf col (max 0 (1- col)))
                   (incf index))
                 ((char= character #\Tab)
                   (setf col (min (1- cols) (* 8 (1+ (floor col 8)))))
                   (incf index))
                 ((>= (char-code character) 32)
                   (setf col (%frame-grid-put-char grid
                                                   row
                                                   col
                                                   character
                                                   style-grid
                                                   current-style))
                   (when (zerop col)
                     (setf row (min (1+ row) (1- rows))))
                   (incf index))
                 (t (incf index)))))
    (values grid style-grid)))

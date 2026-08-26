(in-package #:nerimux/renderer)

(defconstant +frame-grid-continuation+ (code-char 0)
  "Sentinel written into the grid cell immediately right of a double-width
   character (R6.9-frame-grid). %frame-grid-text skips it, so the flattened
   row hands the real wide glyph alone to %surface-draw-text (already
   display-width aware) instead of a synthetic filler that would double the
   column it consumes. #\\Nul never reaches here as real content: the parse
   loop in %ANSI-FRAME-GRID only calls %FRAME-GRID-PUT-CHAR for characters
   with (char-code >= 32).")

(defun %make-frame-grid (rows cols)
  (let ((grid (make-array rows)))
    (dotimes (row rows grid)
      (setf (aref grid row) (make-string cols :initial-element #\Space)))))

(defun %clear-frame-grid (grid)
  (dotimes (row (length grid))
    (fill (aref grid row) #\Space))
  grid)

(defun %frame-grid-params (text)
  (let ((start 0)
        (length (length text))
        (params nil))
    (when (and (plusp length)
               (find (char text 0) "? > !" :test #'char=))
      (incf start))
    (loop for end from start to length
          when (or (= end length)
                   (char= (char text end) #\;))
            do (push (or (parse-integer (subseq text start end)
                                         :junk-allowed t)
                         0)
                     params)
               (setf start (1+ end)))
    (nreverse params)))

(defun %frame-grid-param (params index default)
  (let ((value (nth index params)))
    (if (and value (plusp value)) value default)))

(defun %frame-grid-clear-line (row col mode)
  (case mode
    (1 (fill row #\Space :start 0 :end (min (1+ col) (length row))))
    (2 (fill row #\Space))
    (otherwise (fill row #\Space :start (min col (length row))))))

(defun %frame-grid-apply-csi (grid row col saved-row saved-col params final)
  (let ((height (length grid))
        (width (length (aref grid 0)))
        (count (or (first params) 1)))
    (cond
      ((or (char= final #\A) (char= final #\B))
       (let ((delta (if (plusp count) count 1)))
         (if (char= final #\A)
             (decf row delta)
             (incf row delta))))
      ((or (char= final #\C) (char= final #\D))
       (let ((delta (if (plusp count) count 1)))
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
         (%clear-frame-grid grid)))
      ((char= final #\K)
       (%frame-grid-clear-line (aref grid (max 0 (min row (1- height))))
                               col
                               (or (first params) 0)))
      ((char= final #\s)
       (setf saved-row row
             saved-col col))
      ((char= final #\u)
       (setf row saved-row
             col saved-col)))
    (values (max 0 (min row (1- height)))
            (max 0 (min col width))
            saved-row
            saved-col)))

(defun %frame-grid-put-char (grid row col character)
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
   (combining marks) keeps the pre-fix one-column advance: that class is
   unaffected by this fix and stays as it was."
  (let* ((height (length grid))
         (width (length (aref grid 0)))
         (char-width (if (= 2 (nerimux/terminal/types:char-width character))
                         2
                         1))
         (fits-p (<= (+ col char-width) width)))
    (when (and (<= 0 row) (< row height)
               (<= 0 col) (< col width))
      (setf (char (aref grid row) col) character)
      (when (and fits-p (= char-width 2))
        (setf (char (aref grid row) (1+ col)) +frame-grid-continuation+)))
    (let ((advance (if fits-p char-width 1)))
      (if (< (+ col advance) width)
          (+ col advance)
          0))))

(defun %frame-grid-parse-csi (frame start grid row col saved-row saved-col)
  (let ((end start)
        (length (length frame)))
    (loop while (and (< end length)
                     (not (<= (char-code #\@)
                              (char-code (char frame end))
                              (char-code #\~))))
          do (incf end))
    (if (= end length)
        (values length row col saved-row saved-col)
        (multiple-value-bind (new-row new-col new-saved-row new-saved-col)
            (%frame-grid-apply-csi
             grid row col saved-row saved-col
             (%frame-grid-params (subseq frame start end))
             (char frame end))
          (values (1+ end) new-row new-col new-saved-row new-saved-col)))))

(defun %frame-grid-skip-osc (frame start)
  (let ((index start)
        (length (length frame)))
    (loop while (< index length)
          do (cond
               ((= (char-code (char frame index)) 7)
                (return (1+ index)))
               ((and (= (char-code (char frame index)) 27)
                     (< (1+ index) length)
                     (char= (char frame (1+ index)) #\\))
                (return (+ index 2)))
               (t (incf index)))
          finally (return length))))

(defun %ansi-frame-grid (frame rows cols)
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (grid (%make-frame-grid rows cols))
         (row 0)
         (col 0)
         (saved-row 0)
         (saved-col 0)
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
                         (multiple-value-setq
                             (index row col saved-row saved-col)
                           (%frame-grid-parse-csi
                            frame (+ index 2) grid row col
                            saved-row saved-col)))
                        (#\]
                         (setf index (%frame-grid-skip-osc frame (+ index 2))))
                        (otherwise
                         (incf index 2)))))
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
                  (setf col (min (1- cols)
                                 (* 8 (1+ (floor col 8)))))
                  (incf index))
                 ((>= (char-code character) 32)
                  (setf col (%frame-grid-put-char grid row col character))
                  (when (zerop col)
                    (setf row (min (1+ row) (1- rows))))
                  (incf index))
                 (t
                  (incf index)))))
    grid))

(defun %frame-grid-row (grid row)
  (aref grid row))

(defun %frame-grid-text (grid)
  "Flatten GRID to one newline-joined string. +FRAME-GRID-CONTINUATION+
   cells are omitted rather than written as a space: the wide glyph to
   their left already accounts for both columns once this text reaches
   %SURFACE-DRAW-TEXT (display-width aware), so re-emitting the
   continuation cell as a real character would double-count that column."
  (with-output-to-string (stream)
    (dotimes (row (length grid))
      (loop for character across (%frame-grid-row grid row)
            unless (char= character +frame-grid-continuation+)
              do (write-char character stream))
      (unless (= row (1- (length grid)))
        (terpri stream)))))

(in-package #:nerimux/renderer)

(defconstant +frame-grid-continuation+
  (code-char 0)
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

(defun %clear-frame-grid (grid &optional style-grid style)
  "Blank every character row in GRID.  When STYLE-GRID is supplied, also
   stamp STYLE onto every cell's style row -- the caller passes the BCE
   (back-color-erase) style computed from the current SGR state, so ED
   erases carry the active background forward the way a real terminal
   does (R-style-preservation)."
  (dotimes (row (length grid))
    (fill (aref grid row) #\Space)
    (when style-grid
      (fill (aref style-grid row) style)))
  grid)

(defun %frame-grid-params (text)
  (let ((start 0)
        (length (length text))
        (params nil))
    (when (and (plusp length) (find (char text 0) "? > !" :test #'char=))
      (incf start))
    (loop for
          end from start to length
          when (or (= end length) (char= (char text end) #\;))
            do (push
                (or (parse-integer (subseq text start end) :junk-allowed t) 0)
                params) (setf start (1+ end)))
    (nreverse params)))

(defun %frame-grid-param (params index default)
  (let ((value (nth index params)))
    (if (and value (plusp value))
        value
        default)))

(defvar *%default-style*
  nil
  "Cached CL-TUI-KIT/CORE:STYLE for the unstyled default.  Styles are value
   objects, so every consumer safely shares this one instance instead of
   each allocating its own.")

(defun %default-style ()
  (or *%default-style*
      (setf *%default-style* (cl-tui-kit/core:make-style))))

(defun %bce-style (style)
  "Return the style an EL/ED erase should stamp onto cleared cells.

   Real terminals implement back-color-erase: an erased cell keeps STYLE's
   background and resets every other attribute to default.  When STYLE's
   background is already default, that is exactly %DEFAULT-STYLE, so reuse
   the cached instance rather than allocating an equivalent one."
  (let ((background (cl-tui-kit/core:style-background style)))
    (if (cl-tui-kit/core:color= background (cl-tui-kit/core:default-color))
        (%default-style)
        (cl-tui-kit/core:make-style :background background))))

(defun %make-frame-style-grid (rows cols)
  "A ROWS x COLS grid of styles parallel to %MAKE-FRAME-GRID's character
   grid, every cell initialized to the shared default style."
  (let ((grid (make-array rows))
        (default (%default-style)))
    (dotimes (row rows grid)
      (setf (aref grid row) (make-array cols :initial-element default)))))

(defun %frame-grid-style-row (style-grid row)
  (aref style-grid row))

(defparameter %sgr-named-colors
  #(:black :red :green :yellow :blue :magenta :cyan :white)
  "SGR color index 0-7 in the order 30-37/40-47/90-97/100-107 encode it.")

(defun %sgr-clamp-byte (value)
  (max 0 (min 255 value)))

(defun %sgr-extended-color (codes index length)
  "Parse the 38/48 extended-color form starting at CODES[INDEX] (itself 38
   or 48).  Returns (VALUES COLOR CONSUMED): CONSUMED is how many codes,
   including the leading 38/48, to advance past.  A truncated or malformed
   sequence returns a NIL color and consumes the rest of CODES, so its
   arguments are never re-read as top-level SGR codes."
  (if (>= (1+ index) length)
      (values nil (- length index))
      (let ((mode (aref codes (1+ index))))
        (cond
          ((and (= mode 5) (< (+ index 2) length))
           (values
            (cl-tui-kit/core:indexed-color
             (%sgr-clamp-byte (aref codes (+ index 2))))
            3))
          ((= mode 5) (values nil (- length index)))
          ((and (= mode 2) (< (+ index 4) length))
           (values
            (cl-tui-kit/core:rgb-color
             (%sgr-clamp-byte (aref codes (+ index 2)))
             (%sgr-clamp-byte (aref codes (+ index 3)))
             (%sgr-clamp-byte (aref codes (+ index 4))))
            5))
          ((= mode 2) (values nil (- length index)))
          (t (values nil 2))))))

(defun %frame-grid-apply-sgr (style params)
  "Return a NEW style with the SGR PARAMS (a list of integers from a CSI
   ... m sequence, as %FRAME-GRID-PARAMS returns) applied on top of STYLE.

   Codes with no CL-TUI-KIT representation -- 5 (blink), 8 (conceal) -- are
   ignored without disturbing 38/48 extended-argument parsing."
  (let* ((codes (coerce params 'vector))
         (length (length codes))
         (foreground (cl-tui-kit/core:style-foreground style))
         (background (cl-tui-kit/core:style-background style))
         (bold (cl-tui-kit/core:style-bold style))
         (dim (cl-tui-kit/core:style-dim style))
         (italic (cl-tui-kit/core:style-italic style))
         (underline (cl-tui-kit/core:style-underline style))
         (reverse (cl-tui-kit/core:style-reverse style))
         (strike (cl-tui-kit/core:style-strike style))
         (index 0))
    (loop while (< index length)
          do (let ((code (aref codes index)))
               (cond
                 ((= code 0)
                   (setf foreground (cl-tui-kit/core:default-color)
                         background (cl-tui-kit/core:default-color)
                         bold nil
                         dim nil
                         italic nil
                         underline nil
                         reverse nil
                         strike nil)
                   (incf index))
                 ((= code 1)
                   (setf bold t)
                   (incf index))
                 ((= code 2)
                   (setf dim t)
                   (incf index))
                 ((= code 3)
                   (setf italic t)
                   (incf index))
                 ((or (= code 4) (= code 21))
                   (setf underline t)
                   (incf index))
                 ((= code 22)
                   (setf bold nil
                         dim nil)
                   (incf index))
                 ((= code 23)
                   (setf italic nil)
                   (incf index))
                 ((= code 24)
                   (setf underline nil)
                   (incf index))
                 ((= code 7)
                   (setf reverse t)
                   (incf index))
                 ((= code 27)
                   (setf reverse nil)
                   (incf index))
                 ((= code 9)
                   (setf strike t)
                   (incf index))
                 ((= code 29)
                   (setf strike nil)
                   (incf index))
                 ((= code 39)
                   (setf foreground (cl-tui-kit/core:default-color))
                   (incf index))
                 ((= code 49)
                   (setf background (cl-tui-kit/core:default-color))
                   (incf index))
                 ((<= 30 code 37)
                   (setf foreground (cl-tui-kit/core:named-color
                                     (aref %sgr-named-colors (- code 30))))
                   (incf index))
                 ((<= 40 code 47)
                   (setf background (cl-tui-kit/core:named-color
                                     (aref %sgr-named-colors (- code 40))))
                   (incf index))
                 ((<= 90 code 97)
                   (setf foreground (cl-tui-kit/core:indexed-color
                                     (+ 8 (- code 90))))
                   (incf index))
                 ((<= 100 code 107)
                   (setf background (cl-tui-kit/core:indexed-color
                                     (+ 8 (- code 100))))
                   (incf index))
                 ((or (= code 38) (= code 48))
                  (multiple-value-bind (color consumed) 
                      (%sgr-extended-color codes index length)
                    (when color
                      (if (= code 38)
                          (setf foreground color)
                          (setf background color)))
                    (incf index consumed)))
                 (t (incf index)))))
    (cl-tui-kit/core:make-style :foreground
                                foreground
                                :background
                                background
                                :bold
                                bold
                                :dim
                                dim
                                :italic
                                italic
                                :underline
                                underline
                                :reverse
                                reverse
                                :strike
                                strike)))

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
   (combining marks) keeps the pre-fix one-column advance: that class is
   unaffected by this fix and stays as it was.

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

(defun %frame-grid-row (grid row)
  (aref grid row))

(defun %frame-grid-text (grid)
  "Flatten GRID to one newline-joined string, omitting wide-glyph sentinels."
  (with-output-to-string (stream)
    (dotimes (row (length grid))
      (loop for character across (%frame-grid-row grid row)
            unless (char= character +frame-grid-continuation+)
              do (write-char character stream))
      (unless (= row (1- (length grid)))
        (terpri stream)))))

(defun %frame-grid-row-spans (chars-row styles-row)
  "Group CHARS-ROW into styled text spans, omitting wide-glyph sentinels."
  (let ((spans nil)
        (run-style nil)
        (run nil))
    (flet ((flush ()
             (when run
               (push
                (cl-tui-kit/core:make-text-span (coerce (nreverse run) 'string)
                                                :style
                                                run-style)
                spans)
               (setf run nil))))
      (loop for column from 0 below (length chars-row)
            for character = (char chars-row column)
            unless (char= character +frame-grid-continuation+)
              do (let ((style (aref styles-row column)))
                   (unless 
                       (and run-style (cl-tui-kit/core:style= run-style style))
                     (flush)
                     (setf run-style style))
                   (push character run)))
      (flush))
    (nreverse spans)))

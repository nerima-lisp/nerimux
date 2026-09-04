(in-package #:nerimux/renderer)

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


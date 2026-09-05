(in-package #:nerimux/renderer)

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

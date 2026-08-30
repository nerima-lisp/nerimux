(in-package #:nerimux/terminal/actions)

;;;; Cell placement primitives used by the character-writing flow.

(declaim (inline %mark-dirty))
(defun %mark-dirty (screen)
  (setf (screen-dirty-p screen) t))

(defun %advance-cursor (screen count)
  "Advance by COUNT columns, preserving VT100 deferred-wrap semantics."
  (let ((next-x (+ (screen-cursor-x screen) count)))
    (cond ((< next-x (screen-width screen))
           (setf (screen-cursor-x screen) next-x))
          ((screen-autowrap screen)
           (setf (screen-cursor-x screen) (1- (screen-width screen))
                 (screen-pending-wrap screen) t))
          (t
           (setf (screen-cursor-x screen) (1- (screen-width screen)))))))

(defun %place-wide-char (screen x y char fg bg attrs attrs2 ul-color hyperlink)
  "Place CHAR at X,Y and create its zero-width continuation cell when possible."
  (setf (screen-cell screen x y)
        (make-cell :char char :fg fg :bg bg :attrs attrs :attrs2 attrs2
                   :ul-color ul-color :hyperlink hyperlink :width 2))
  (when (< (1+ x) (screen-width screen))
    (setf (screen-cell screen (1+ x) y)
          (make-cell :char #\Space :fg fg :bg bg :attrs attrs :attrs2 attrs2
                     :ul-color ul-color :hyperlink hyperlink :width 0))))

(defun %combining-target-x (screen)
  "Return the lead-cell column to which a combining mark belongs."
  (let ((x (screen-cursor-x screen)))
    (cond ((zerop x) 0)
          ((and (> x 1)
                (zerop (cell-width
                        (screen-cell screen (1- x) (screen-cursor-y screen)))))
           (- x 2))
          (t (1- x)))))

(defun %append-combining-char (screen ch)
  "Append CH to the grapheme at the cursor without advancing the cursor."
  (let* ((x (%combining-target-x screen))
         (y (screen-cursor-y screen))
         (cell (screen-cell screen x y)))
    (setf (screen-cell screen x y)
          (make-cell :char (cell-char cell)
                     :fg (cell-fg cell)
                     :bg (cell-bg cell)
                     :attrs (cell-attrs cell)
                     :attrs2 (cell-attrs2 cell)
                     :ul-color (cell-ul-color cell)
                     :combining (append (cell-combining cell) (list ch))
                     :width (cell-width cell)))
    (%mark-dirty screen)))

(defun %write-wide-cell (screen ch)
  "Write double-width CH at the cursor and advance by two columns."
  (let ((fg (screen-cur-fg screen))
        (bg (screen-cur-bg screen))
        (attrs (screen-cur-attrs screen))
        (attrs2 (screen-cur-attrs2 screen))
        (ul-color (screen-cur-ul-color screen)))
    (when (>= (1+ (screen-cursor-x screen)) (screen-width screen))
      (setf (screen-cell screen (screen-cursor-x screen) (screen-cursor-y screen))
            (blank-cell)
            (screen-cursor-x screen) 0)
      (cursor-down/scroll screen))
    (%place-wide-char screen
                      (screen-cursor-x screen)
                      (screen-cursor-y screen)
                      ch fg bg attrs attrs2 ul-color
                      (screen-current-hyperlink screen))
    (%mark-dirty screen)
    (%advance-cursor screen 2)))

(defun %write-normal-cell (screen ch)
  "Write single-width CH at the cursor and advance by one column."
  (let ((x (screen-cursor-x screen))
        (y (screen-cursor-y screen)))
    (setf (screen-cell screen x y)
          (make-cell :char ch
                     :fg (screen-cur-fg screen)
                     :bg (screen-cur-bg screen)
                     :attrs (screen-cur-attrs screen)
                     :attrs2 (screen-cur-attrs2 screen)
                     :ul-color (screen-cur-ul-color screen)
                     :hyperlink (screen-current-hyperlink screen)
                     :width 1))
    (%mark-dirty screen)
    (%advance-cursor screen 1)))

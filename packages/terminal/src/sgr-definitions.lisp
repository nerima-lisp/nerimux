(in-package #:nerimux/terminal/sgr)

(declaim (inline attr-on attr-off attr2-on attr2-off))

(defun attr-on (screen bit)
  "Enable SGR attribute BIT on SCREEN."
  (setf (screen-cur-attrs screen) (logior (screen-cur-attrs screen) bit)))

(defun attr-off (screen bit)
  "Disable SGR attribute BIT on SCREEN."
  (setf (screen-cur-attrs screen) (logand (screen-cur-attrs screen)
                                          (lognot bit))))

(defun attr2-on (screen bit)
  "Enable extended SGR attribute BIT on SCREEN."
  (setf (screen-cur-attrs2 screen) (logior (screen-cur-attrs2 screen) bit)))

(defun attr2-off (screen bit)
  "Disable extended SGR attribute BIT on SCREEN."
  (setf (screen-cur-attrs2 screen) (logand (screen-cur-attrs2 screen)
                                           (lognot bit))))

(defmacro define-sgr-rules (&rest rules)
  "Define the single-parameter SGR dispatcher from declarative RULES."
  `(defun %dispatch-sgr-code (screen p)
     "Apply one SGR parameter P to SCREEN, ignoring unknown codes."
     (declare (type screen screen)
              (type fixnum p)
              (ignorable p))
     (cond
       ,@(mapcar
          (lambda (rule)
            (destructuring-bind (condition &rest body) rule
              `(,condition ,@body)))
          rules)
       (t (values)))))

(define-sgr-rules ((= p 0) (reset-sgr-pen screen))
                  ((= p 1) (attr-on screen +attr-bold+))
                  ((= p 2) (attr-on screen +attr-dim+))
                  ((= p 3) (attr-on screen +attr-italic+))
                  ((= p 4) (attr-on screen +attr-underline+))
                  ((= p 5) (attr-on screen +attr-blink+))
                  ((= p 6) (attr-on screen +attr-blink+))
                  ((= p 7) (attr-on screen +attr-reverse+))
                  ((= p 8) (attr-on screen +attr-conceal+))
                  ((= p 9) (attr-on screen +attr-strikethrough+))
                  ((= p 21) (attr2-on screen +attr2-double-underline+))
                  ((= p 53) (attr2-on screen +attr2-overline+))
                  ((= p 55) (attr2-off screen +attr2-overline+))
                  ((<= 51 p 52) (values))
                  ((= p 22) (attr-off screen (logior +attr-bold+ +attr-dim+)))
                  ((= p 23) (attr-off screen +attr-italic+))
                  ((= p 24)
                   (progn
                     (attr-off screen +attr-underline+)
                     (attr2-off screen +attr2-double-underline+)))
                  ((= p 25) (attr-off screen +attr-blink+))
                  ((= p 27) (attr-off screen +attr-reverse+))
                  ((= p 28) (attr-off screen +attr-conceal+))
                  ((= p 29) (attr-off screen +attr-strikethrough+))
                  ((= p 59)
                   (setf (screen-cur-ul-color screen) 0))
                  ((<= 30 p 37)
                   (setf (screen-cur-fg screen) (- p 30)))
                  ((= p 39)
                   (setf (screen-cur-fg screen) +default-color+))
                  ((<= 40 p 47)
                   (setf (screen-cur-bg screen) (- p 40)))
                  ((= p 49)
                   (setf (screen-cur-bg screen) +default-color+))
                  ((<= 90 p 97)
                   (setf (screen-cur-fg screen) (+ 8 (- p 90))))
                  ((<= 100 p 107)
                   (setf (screen-cur-bg screen) (+ 8 (- p 100)))))

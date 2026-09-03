(in-package #:nerimux/terminal/sgr)

(defun %emit-sgr-color (out color background-p)
  "Write COLOR as an SGR fragment to OUT."
  (cond
    ((= color +default-color+)
     (format out
             ";~D"
             (if background-p
                 49
                 39)))
    ((logtest color +true-color-flag+)
     (format out
             ";~D;2;~D;~D;~D"
             (if background-p
                 48
                 38)
             (ldb (byte 8 16) color)
             (ldb (byte 8 8) color)
             (ldb (byte 8 0) color)))
    ((<= 0 color 7)
     (format out
             ";~D"
             (+
              (if background-p
                  40
                  30)
              color)))
    ((<= 8 color 15)
     (format out
             ";~D"
             (+
              (if background-p
                  100
                  90)
              (- color 8))))
    ((<= 16 color 255)
     (format out
             ";~D;5;~D"
             (if background-p
                 48
                 38)
             color))))

(defun %pen-to-sgr-params (fg bg attrs attrs2)
  "Return the SGR parameter string that reconstructs the supplied pen."
  (with-output-to-string (out)
    (write-char #\0 out)
    (when (logtest attrs +attr-bold+)
      (format out ";~D" 1))
    (when (logtest attrs +attr-dim+)
      (format out ";~D" 2))
    (when (logtest attrs +attr-italic+)
      (format out ";~D" 3))
    (when (logtest attrs +attr-underline+)
      (format out ";~D" 4))
    (when (logtest attrs +attr-blink+)
      (format out ";~D" 5))
    (when (logtest attrs +attr-reverse+)
      (format out ";~D" 7))
    (when (logtest attrs +attr-conceal+)
      (format out ";~D" 8))
    (when (logtest attrs +attr-strikethrough+)
      (format out ";~D" 9))
    (when (logtest attrs2 +attr2-double-underline+)
      (format out ";~D" 21))
    (when (logtest attrs2 +attr2-overline+)
      (format out ";~D" 53))
    (unless (= fg +default-color+)
      (%emit-sgr-color out fg nil))
    (unless (= bg +default-color+)
      (%emit-sgr-color out bg t))))

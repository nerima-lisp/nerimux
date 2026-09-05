(in-package #:nerimux/test/terminal)

(describe "terminal-suite/ground-state-control-bytes"

  (it "ground-state-ignored-bytes-table"
    (dolist (row '((#x7F "DEL must return ground-state"          "DEL must not write a visible character")
                   (#x0E "SO must return ground-state"           "SO must not write a visible character")
                   (#x0F "SI must return ground-state"           "SI must not write a visible character")))
      (destructuring-bind (byte state-desc char-desc) row
        (declare (ignore state-desc char-desc))
        (let ((s (make-screen 10 5)))
          (let ((next (nerimux/terminal/parser:ground-state s byte)))
            (expect (eq #'nerimux/terminal/parser:ground-state next))
            (expect (char= #\Space (char-at s 0 0))))))))

  (it "ground-state-stray-continuation-byte-emits-replacement"
    (let ((s (make-screen 10 5)))
      (nerimux/terminal/parser:ground-state s #x80)
      (expect (char= (code-char #xFFFD) (char-at s 0 0)))))

  (it "ground-state-unhandled-c0-is-ignored"
    (let ((s (make-screen 10 5)))
      (let ((next (nerimux/terminal/parser:ground-state s #x01)))
        (expect (eq #'nerimux/terminal/parser:ground-state next)))
      (let ((next2 (nerimux/terminal/parser:ground-state s #x02)))
        (expect (eq #'nerimux/terminal/parser:ground-state next2)))))

  (it "escape-state-unrecognized-byte-returns-ground"
    (let ((s (make-screen 10 5)))
      (let ((next (nerimux/terminal/parser:escape-state s #x40)))
        (expect (eq #'nerimux/terminal/parser:ground-state next)))))

  (it "escape-state-m-reverse-index-returns-ground"
    (with-screen (s 10 5)
      (feed s (esc "[3;1H"))    ; move to row 2 (0-based)
      (let ((next (nerimux/terminal/parser:escape-state s #x4D)))
        (expect (eq #'nerimux/terminal/parser:ground-state next))
        (expect (= 1 (screen-cursor-y s))))))

  (it "escape-state-7-saves-cursor"
    (with-screen (s 10 5)
      (feed s (esc "[3;6H"))    ; cursor -> (5, 2)
      (let ((next (nerimux/terminal/parser:escape-state s #x37)))
        (expect (eq #'nerimux/terminal/parser:ground-state next))
        (expect (not (null (nerimux/terminal/types:screen-saved-cursor s)))))))

  (it "escape-state-8-restores-cursor"
    (with-screen (s 10 5)
      (feed s (esc "[3;6H"))    ; cursor -> (5, 2)
      (feed s (esc "7"))        ; ESC 7 -- save
      (feed s (esc "[1;1H"))    ; move to origin
      (let ((next (nerimux/terminal/parser:escape-state s #x38)))
        (expect (eq #'nerimux/terminal/parser:ground-state next))
        (check-cursor s 5 2))))

  (it "escape-state-P-dcs-returns-continuation"
    (with-screen (s 10 5)
      (let ((next (nerimux/terminal/parser:escape-state s #x50)))
        (expect (functionp next)))))

  (it "escape-state-open-paren-returns-charset-designator"
    (with-screen (s 10 5)
      (let ((next (nerimux/terminal/parser:escape-state s #x28)))
        (expect (functionp next))
        (funcall next s 48)                ; '0' -> DEC graphics
        (expect (eq :dec-graphics (nerimux/terminal/types:screen-g0-charset s))))))

  (it "escape-state-close-bracket-returns-osc-state"
    (with-screen (s 10 5)
      (let ((next (nerimux/terminal/parser:escape-state s #x5D)))
        (expect (eq #'nerimux/terminal/parser:osc-state next))))))

(describe "terminal-suite/direct-dcs-suite"

  (it "make-dcs-k-consumes-payload-bytes"
    (let* ((s  (make-screen 10 5))
           (k0 (nerimux/terminal/parser::make-dcs-k))
           (k1 (funcall k0 s (char-code #\H))))
      (expect (functionp k1))))

  (it "make-dcs-k-terminates-on-esc-backslash"
    (let* ((s   (make-screen 10 5))
           (k0  (nerimux/terminal/parser::make-dcs-k))
           (k1  (funcall k0 s (char-code #\X)))
           (k2  (funcall k1 s #x1B))
           (result (funcall k2 s #x5C)))
      (expect (eq #'nerimux/terminal/parser:ground-state result))))

  (it "make-dcs-k-non-backslash-after-esc-continues"
    (let* ((s   (make-screen 10 5))
           (k0  (nerimux/terminal/parser::make-dcs-k))
           (k1  (funcall k0 s #x1B))     ; ESC -> waiting for backslash
           (k2  (funcall k1 s (char-code #\A))))
      (expect (functionp k2))))


  (it "g2-g3-designation-and-locking-shifts"
    (with-screen (s 20 5)
      (feed s (format nil "~C*0" #\Escape))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-g2-charset s)))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))
      (feed s "q")
      (expect (char= #\q (char-at s 0 0)))
      (feed s (format nil "~Cn" #\Escape))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))
      (feed s "q")
      (expect (char= #\─ (char-at s 1 0)))
      (feed s (format nil "~Co" #\Escape))
      (feed s "q")
      (expect (char= #\q (char-at s 2 0)))))

  (it "ss2-single-shift-maps-one-character"
    (with-screen (s 20 5)
      (feed s (format nil "~C*0" #\Escape))     ; G2 = DEC graphics
      (feed s (format nil "~CNq" #\Escape))     ; SS2 + q
      (feed s "q")                              ; plain q afterwards
      (expect (char= #\─ (char-at s 0 0)))
      (expect (char= #\q (char-at s 1 0)))))

  (it "ris-resets-g2-g3-and-single-shift"
    (with-screen (s 20 5)
      (feed s (format nil "~C*0~C+0~CN" #\Escape #\Escape #\Escape))
      (feed s (format nil "~Cc" #\Escape))
      (expect (eq :ascii (nerimux/terminal/types:screen-g2-charset s)))
      (expect (eq :ascii (nerimux/terminal/types:screen-g3-charset s)))
      (expect (null (nerimux/terminal/types:screen-single-shift s))))))

(in-package #:nerimux/test/terminal)

(describe "terminal-suite/direct-parser-cps-suite"


  (it "ground-state-printable-writes-and-stays-ground"
    (with-screen (s 10 5)
      (let ((next (nerimux/terminal/parser:ground-state s 65))) ; 65 = #\A
        (expect (eq #'nerimux/terminal/parser:ground-state next))
        (expect (char= #\A (char-at s 0 0))))))

  (it "ground-state-escape-returns-escape-state"
    (with-screen (s 10 5)
      (let ((next (nerimux/terminal/parser:ground-state s #x1B)))
        (expect (eq #'nerimux/terminal/parser:escape-state next))
        (expect (char= #\Space (char-at s 0 0))))))


  (it "escape-state-bracket-returns-csi-k"
    (with-screen (s 10 5)
      (let ((next (nerimux/terminal/parser:escape-state s #x5B)))
        (expect (functionp next)))))

  (it "escape-state-c-returns-ground-and-resets"
    (with-screen (s 10 5)
      (feed s "hello")
      (let ((next (nerimux/terminal/parser:escape-state s #x63)))
        (expect (eq #'nerimux/terminal/parser:ground-state next))
        (expect (row-blank-p s 0)))))


  (it "charset-designator-always-returns-ground-state"
    (with-screen (s 10 5)
      (expect (eq #'nerimux/terminal/parser:ground-state
              (funcall (nerimux/terminal/parser:make-charset-designator-k :g0) s 66)))  ; B = ASCII
      (expect (eq #'nerimux/terminal/parser:ground-state
              (funcall (nerimux/terminal/parser:make-charset-designator-k :g0) s 48))))) ; 0 = graphics

  (it "esc-paren-0-designates-and-activates-g0-line-drawing"
    (with-screen (s 10 5)
      (feed s (format nil "~C(0" #\Escape))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-g0-charset s)))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))))

  (it "esc-close-paren-0-designates-g1-without-activating"
    (with-screen (s 10 5)
      (feed s (format nil "~C)0" #\Escape))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-g1-charset s)))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "so-invokes-g1-si-invokes-g0"
    (with-screen (s 10 5)
      (feed s (format nil "~C)0" #\Escape))            ; designate G1 = line-drawing
      (feed s (string (code-char #x0E)))               ; SO
      (expect (eq :g1 (nerimux/terminal/types:screen-active-g s)))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-charset s)))
      (feed s (string (code-char #x0F)))               ; SI
      (expect (eq :g0 (nerimux/terminal/types:screen-active-g s)))
      (expect (eq :ascii (nerimux/terminal/types:screen-charset s)))))

  (it "g1-line-drawing-via-so-remaps-characters"
    (with-screen (s 10 5)
      (feed s (format nil "~C)0~Cq" #\Escape (code-char #x0E)))  ; ESC ) 0, SO, 'q'
      (expect (string= "─" (row-string s 0 :end 1)))))


  (it "esc-d-ind-moves-cursor-down-keeping-column"
    (with-screen (s 20 5)
      (feed s (esc "[3;5H"))   ; CUP → row 3, col 5 (cursor x=4, y=2)
      (feed s (esc "D"))       ; ESC D → IND
      (expect (= 4 (nerimux/terminal/types:screen-cursor-x s)))
      (expect (= 3 (nerimux/terminal/types:screen-cursor-y s)))))

  (it "esc-e-nel-moves-to-start-of-next-line"
    (with-screen (s 20 5)
      (feed s (esc "[3;5H"))   ; CUP → row 3, col 5
      (feed s (esc "E"))       ; ESC E → NEL
      (expect (= 0 (nerimux/terminal/types:screen-cursor-x s)))
      (expect (= 3 (nerimux/terminal/types:screen-cursor-y s)))))


  (it "osc-state-bel-terminates-to-ground"
    (with-screen (s 10 5)
      (expect (eq #'nerimux/terminal/parser:ground-state
              (nerimux/terminal/parser:osc-state s #x07)))))

  (it "osc-state-other-bytes-stay-in-osc"
    (with-screen (s 10 5)
      (let ((k65 (nerimux/terminal/parser:osc-state s 65)))   ; 'A'
        (expect (functionp k65)))
      (let ((k59 (nerimux/terminal/parser:osc-state s 59)))   ; ';'
        (expect (functionp k59))
        (expect (eq #'nerimux/terminal/parser:ground-state
                (funcall k59 s #x07))))))


  (it "osc-st-state-byte-dispatch"
    (with-screen (s 10 5)
      (expect (eq #'nerimux/terminal/parser:ground-state
              (nerimux/terminal/parser::osc-st-state s #x5C)))
      (expect (eq #'nerimux/terminal/parser:osc-state
              (nerimux/terminal/parser::osc-st-state s 65)))))


  (it "make-csi-k-accumulates-digits-and-dispatches"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-csi-k))
             (k1 (funcall k0 s 51))   ; '3' = #x33
             (k2 (funcall k1 s 49))   ; '1' = #x31
             (result (funcall k2 s 109))) ; 'm' = #x6D = SGR final
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (= 1 (nerimux/terminal/types:screen-cur-fg s))))))

  (it "make-csi-k-semicolon-separates-params"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-csi-k))
             (k1 (funcall k0 s 49))    ; '1'
             (k2 (funcall k1 s 59))    ; ';'
             (k3 (funcall k2 s 51))    ; '3'
             (k4 (funcall k3 s 49))    ; '1'
             (result (funcall k4 s 109))) ; 'm'
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (= 1 (nerimux/terminal/types:screen-cur-fg s)))
        (expect (logbitp 0 (nerimux/terminal/types:screen-cur-attrs s))))))

  (it "make-csi-k-dec-marker-question-sets-intermed"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cursor-visible s) nil)
      (let* ((k0 (nerimux/terminal/parser:make-csi-k))
             (k1 (funcall k0 s #x3F))    ; '?'
             (k2 (funcall k1 s 50))      ; '2'
             (k3 (funcall k2 s 53))      ; '5'
             (result (funcall k3 s #x68))) ; 'h' = ?25h
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (nerimux/terminal/types:screen-cursor-visible s)))))

  (it "make-csi-k-sec-da-marker-sets-intermed"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-csi-k))
             (k1 (funcall k0 s #x3E))    ; '>'
             (result (funcall k1 s #x63))) ; 'c' = DA2
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (consp (nerimux/terminal/types:screen-response-queue s))))))

  (it "make-csi-k-intermediate-byte-space-sets-intermed"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-csi-k))
             (k1 (funcall k0 s 50))    ; '2' = param 2
             (k2 (funcall k1 s #x20))  ; SPACE = intermediate
             (result (funcall k2 s #x71))) ; 'q' = DECSCUSR final
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (= 2 (nerimux/terminal/types:screen-cursor-shape s))))))

  (it "make-csi-k-non-final-invalid-byte-aborts-to-ground"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-csi-k))
             (result (funcall k0 s #x01)))
        (expect (eq #'nerimux/terminal/parser:ground-state result)))))


  (it "make-utf8-k-assembles-two-byte-sequence"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-utf8-k 3 1))
             (result (funcall k0 s #xA9)))  ; continuation byte
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (char= #\é (char-at s 0 0))))))

  (it "make-utf8-k-assembles-three-byte-sequence"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-utf8-k 3 2))
             (k1 (funcall k0 s #x81))    ; first continuation byte
             (result (funcall k1 s #x82))) ; second continuation byte
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (char= #\あ (char-at s 0 0))))))

  (it "make-utf8-k-malformed-non-continuation-emits-fffd"
    (with-screen (s 10 5)
      (let* ((k0 (nerimux/terminal/parser:make-utf8-k 2 1)))
        (funcall k0 s #x41))   ; ASCII 'A' — not a continuation byte
      (expect (char= (code-char #xFFFD) (char-at s 0 0)))
      (expect (char= #\A (char-at s 1 0)))))


  (it "define-state-macro-is-defined"
    (expect (macro-function 'nerimux/terminal/parser::define-state))))

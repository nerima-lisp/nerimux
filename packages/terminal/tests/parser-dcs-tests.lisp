(in-package #:nerimux/test/terminal)

(defun %fresh-dcs-buffer ()
  "A fresh empty adjustable octet buffer for make-dcs-st-k / make-dcs-k tests."
  (make-array 16 :element-type '(unsigned-byte 8) :fill-pointer 0 :adjustable t))

(describe "terminal-suite/direct-dcs-st-suite"

  (it "make-dcs-st-k-backslash-returns-ground"
    (let* ((s   (make-screen 10 5))
           (k   (nerimux/terminal/parser::make-dcs-st-k (%fresh-dcs-buffer)))
           (result (funcall k s #x5C)))
      (expect (eq #'nerimux/terminal/parser:ground-state result))))

  (it "make-dcs-st-k-non-backslash-resumes-consuming"
    (let* ((s   (make-screen 10 5))
           (k   (nerimux/terminal/parser::make-dcs-st-k (%fresh-dcs-buffer)))
           (result (funcall k s (char-code #\A))))
      (expect (functionp result))))


  (it "dcs-passthrough-tmux-prefix-queues-inner-sequence"
    (let ((s (make-screen 10 5)))
      (nerimux/terminal/emulator:screen-process-bytes
       s (coerce (list #x1B #x50               ; ESC P (DCS)
                       116 109 117 120 59      ; tmux;
                       #x1B #x1B 93 49 51 51 55 ; \e\e ] 1 3 3 7  (doubled ESC)
                       #x1B #x5C)              ; ESC \\  (ST)
                 '(vector (unsigned-byte 8))))
      (let ((queue (nerimux/terminal/types:screen-passthrough-queue s)))
        (expect (= 1 (length queue)))
        (let ((seq (first queue)))
          (expect (char= #\Escape (char seq 0)))
          (expect (string= "]1337" (subseq seq 1)))))))

  (it "dcs-non-tmux-prefix-is-discarded"
    (let ((s (make-screen 10 5)))
      (nerimux/terminal/emulator:screen-process-bytes
       s (coerce (list #x1B #x50 113 35 48 #x1B #x5C) '(vector (unsigned-byte 8))))
      (expect (null (nerimux/terminal/types:screen-passthrough-queue s))))))

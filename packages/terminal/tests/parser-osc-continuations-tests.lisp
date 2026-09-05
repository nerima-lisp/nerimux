(in-package #:nerimux/test/terminal)

(defun make-osc-payload-buf (string)
  "Return a fresh adjustable (unsigned-byte 8) buffer pre-filled with the
   bytes of STRING (one byte per character, Latin-1 encoded)."
  (let ((buf
         (make-array (length string)
                     :element-type
                     '(unsigned-byte 8)
                     :fill-pointer
                     0
                     :adjustable
                     t)))
    (loop for ch across string
          do (vector-push-extend (char-code ch) buf))
    buf))

(describe "terminal-suite/direct-osc-continuations"

  (it "make-osc-k-accumulates-and-dispatches-on-bel"
    (with-screen (s 20 5)
      (let ((buf (make-osc-payload-buf "0;hello"))
            (k   nil))
        (setf k (nerimux/terminal/parser::make-osc-k buf))
        (let ((result (funcall k s #x07)))
          (expect (eq #'nerimux/terminal/parser:ground-state result))
          (expect (string= "hello" (nerimux/terminal/types:screen-title s)))))))

  (it "make-osc-k-esc-transitions-to-st-state"
    (with-screen (s 10 5)
      (let* ((buf (make-osc-payload-buf ""))
             (k   (nerimux/terminal/parser::make-osc-k buf))
             (k2  (funcall k s #x1B)))
        (expect (functionp k2)))))

  (it "make-osc-st-k-backslash-dispatches-and-grounds"
    (with-screen (s 20 5)
      (let* ((buf    (make-osc-payload-buf "2;xterm-st-title"))
             (k      (nerimux/terminal/parser::make-osc-st-k buf))
             (result (funcall k s #x5C)))      ; backslash = ST confirmed
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (string= "xterm-st-title" (nerimux/terminal/types:screen-title s))))))

  (it "make-osc-st-k-non-backslash-returns-ground"
    (with-screen (s 20 5)
      (let* ((buf    (make-osc-payload-buf "0;title"))
             (k      (nerimux/terminal/parser::make-osc-st-k buf))
             (result (funcall k s (char-code #\X)))) ; not a backslash
        (expect (eq #'nerimux/terminal/parser:ground-state result))
        (expect (not (string= "title" (nerimux/terminal/types:screen-title s))))))))

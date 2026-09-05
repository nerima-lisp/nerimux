(in-package #:nerimux/test/terminal)

(describe "terminal-suite/osc-dispatch-edge-cases"

  (it "osc-command-parser-rejects-invalid-and-accepts-zero"
    (expect (null (nerimux/terminal/parser::%parse-osc-command "x;body" 1)))
    (expect (= 0 (nerimux/terminal/parser::%parse-osc-command "0;body" 1))))

  (it "osc-133-only-marks-prompt-for-an-a-body"
    (with-screen (s 20 5)
      (let ((before (copy-list (nerimux/terminal/types:screen-prompt-marks s))))
        (nerimux/terminal/parser::%handle-osc-133 s "")
        (nerimux/terminal/parser::%handle-osc-133 s "B")
        (expect (equal before (nerimux/terminal/types:screen-prompt-marks s)))
        (nerimux/terminal/parser::%handle-osc-133 s "A")
        (expect (= 1 (length (nerimux/terminal/types:screen-prompt-marks s)))))))

  (it "osc-133-dispatches-through-the-command-table"
    (with-screen (s 20 5)
      (nerimux/terminal/parser::%dispatch-osc
       s
       (cl-codec-kit:string-to-octets "133;A" :encoding :utf-8))
      (expect (= 1 (length (nerimux/terminal/types:screen-prompt-marks s))))))

  (it "osc-payload-no-semicolon-is-noop"
    (with-screen (s 20 5)
      (finishes
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]notanumber~C" #\Escape (code-char 7))
            :encoding :utf-8)))
      (let ((title (nerimux/terminal/types:screen-title s)))
        (expect (or (null title) (string= "" title))))))

  (it "osc-unknown-command-is-silently-ignored"
    (with-screen (s 20 5)
      (finishes
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]99;some-data~C" #\Escape (code-char 7))
            :encoding :utf-8)))
      (let ((title (nerimux/terminal/types:screen-title s)))
        (expect (or (null title) (string= "" title))))))

  (it "osc-empty-payload-bel-is-noop"
    (with-screen (s 20 5)
      (feed s "A")
      (screen-process-bytes s
        (make-array 3 :element-type '(unsigned-byte 8)
                      :initial-contents (list #x1B #x5D #x07)))
      (feed s "B")
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))))

  (it "osc-malformed-utf8-payload-is-replaced-with-u+fffd-not-sub"
    (with-screen (s 20 5)
      (screen-process-bytes s
        (make-array 8 :element-type '(unsigned-byte 8)
                      :initial-contents (list #x1B #x5D #x30 #x3B
                                              #xED #xA0 #x80 #x07)))
      (let ((title (nerimux/terminal/types:screen-title s)))
        (expect (stringp title))
        (expect (plusp (length title)))
        (expect (every (lambda (c) (char= c #\REPLACEMENT_CHARACTER)) title))
        (expect (notany (lambda (c) (= #x1A (char-code c))) title)))))

  (it "osc-malformed-utf8-keeps-surrounding-valid-text"
    (with-screen (s 20 5)
      (screen-process-bytes s
        (make-array 10 :element-type '(unsigned-byte 8)
                       :initial-contents (list #x1B #x5D #x30 #x3B
                                               #x41 #xED #xA0 #x80 #x42 #x07)))
      (let ((title (nerimux/terminal/types:screen-title s)))
        (expect (stringp title))
        (expect (char= #\A (char title 0)))
        (expect (char= #\B (char title (1- (length title)))))
        (expect (find #\REPLACEMENT_CHARACTER title))
        (expect (notany (lambda (c) (= #x1A (char-code c))) title))))))

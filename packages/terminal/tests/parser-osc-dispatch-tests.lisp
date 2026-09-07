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

  (it "osc-99-is-a-known-raw-notification"
    (with-screen (s 20 5)
      (screen-process-bytes s
        (cl-codec-kit:string-to-octets
          (format nil "~C]99;some-data~C" #\Escape (code-char 7))
          :encoding :utf-8))
      (let ((entry (car (nerimux/terminal/types:screen-notification-queue s))))
        (expect (equalp #(27 93 57 57 59 115 111 109 101 45 100 97 116 97 7)
                        (car entry)))
        (expect (string= "some-data" (cdr entry))))))

  (it "osc-9-99-777-are-recorded-from-terminal-bytes"
    (with-screen (s 20 5)
      (dolist (case (list (list #(27 93 57 59 110 105 110 101 7) "nine")
                          (list #(27 93 57 57 59 110 105 110 101 116 121 45 110 105 110 101 7)
                                "ninety-nine")
                          (list #(27 93 55 55 55 59 115 101 118 101 110 45 115 101 118 101 110 45 115 101 118 101 110 7)
                                "seven-seven-seven")))
        (screen-process-bytes s (first case)))
      (let ((entries (nreverse (nerimux/terminal/types:screen-notification-queue s))))
        (expect (= 3 (length entries)))
        (loop for case in (list (list #(27 93 57 59 110 105 110 101 7) "nine")
                                (list #(27 93 57 57 59 110 105 110 101 116 121 45 110 105 110 101 7)
                                      "ninety-nine")
                                (list #(27 93 55 55 55 59 115 101 118 101 110 45 115 101 118 101 110 45 115 101 118 101 110 7)
                                      "seven-seven-seven"))
              for entry in entries
              do (expect (equalp (first case) (car entry)))
                 (expect (string= (second case) (cdr entry)))))))

  (it "osc-998-remains-an-unknown-command"
    (with-screen (s 20 5)
      (finishes
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]998;some-data~C" #\Escape (code-char 7))
            :encoding :utf-8)))
      (expect (null (nerimux/terminal/types:screen-notification-queue s)))))

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

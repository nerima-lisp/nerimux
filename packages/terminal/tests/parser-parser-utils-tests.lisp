(in-package #:nerimux/test/terminal)

(defun make-bytes (&rest byte-values)
  "Return a simple (unsigned-byte 8) vector containing BYTE-VALUES."
  (make-array (length byte-values)
              :element-type
              '(unsigned-byte 8)
              :initial-contents
              byte-values))

(defun feed-osc (screen command-number body-string)
  "Feed an OSC sequence with integer COMMAND-NUMBER and BODY-STRING to SCREEN,
   terminated by BEL (ASCII 7).  Uses UTF-8 encoding to match real terminal behaviour."
  (screen-process-bytes screen
                        (cl-codec-kit:string-to-octets
                         (format nil
                                 "~C]~D;~A~C"
                                 #\Escape
                                 command-number
                                 body-string
                                 (code-char 7))
                         :encoding
                         :utf-8)))

(describe "terminal-suite/parser-helper-suite"

  (it "make-bytes-helper"
    (let ((bytes (make-bytes #x1B #x5D #x07)))
      (expect (= 3 (length bytes)))
      (expect (= #x1B (aref bytes 0)))
      (expect (= #x5D (aref bytes 1)))
      (expect (= #x07 (aref bytes 2)))))

  (it "feed-osc-helper"
    (with-screen (s 20 5)
      (feed-osc s 0 "test-title")
      (expect (string= "test-title" (nerimux/terminal/types:screen-title s)))))

  (it-each ((#x40 t)      ; '@' — low boundary
            (#x4D t)      ; 'M' — mid-range final byte
            (#x7E t)      ; '~' — high boundary
            (#x3F nil)    ; '?' — private marker, below range
            (#x30 nil)    ; '0' — parameter byte
            (#x7F nil))   ; DEL — above range
      "csi-final-byte-p #x~X → ~A"
      (byte expected)
    (expect (eq expected (and (nerimux/terminal/parser:csi-final-byte-p byte) t))))

  (it-each ((#x3F t)      ; '?' — private marker
            (#x30 t)      ; '0' — parameter digit
            (#x3B t)      ; ';' — parameter separator
            (#x40 nil)    ; '@' — at the low boundary (already final)
            (#x4D nil)    ; 'M' — in the final-byte range
            (#x7E nil))   ; '~' — high boundary
      "csi-final-byte-before-p #x~X → ~A"
      (byte expected)
    (expect (eq expected (and (nerimux/terminal/parser:csi-final-byte-before-p byte) t)))))

(describe "terminal-suite/parser-suite"

  (it "screen-process-bytes-zero-length-buffer-is-noop"
    (with-screen (s 10 5)
      (let ((buf (make-array 0 :element-type '(unsigned-byte 8))))
        (screen-process-bytes s buf :start 0 :end 0))
      (expect (char= #\Space (char-at s 0 0))))))

(describe "terminal-suite/base64-decode-suite"

  (it "base64-decode-basic-string"
    (let ((result (nerimux/terminal/parser::%base64-decode "aGVsbG8=")))
      (expect (not (null result)))
      (expect (string= "hello"
                       (cl-codec-kit:octets-to-string result :encoding :utf-8)))))

  (it "base64-decode-empty-string"
    (let ((result (nerimux/terminal/parser::%base64-decode "")))
      (expect (or (null result) (zerop (length result))))))

  (it "base64-decode-truncated-group"
    (finishes (nerimux/terminal/parser::%base64-decode "YQ"))
    (let ((result (nerimux/terminal/parser::%base64-decode "YQ==")))
      (expect (not (null result)))))


  (it "parse-osc-command-returns-nil-for-non-integer"
    (let ((result (nerimux/terminal/parser::%parse-osc-command "notanumber" 10)))
      (expect (null result))))

  (it "parse-osc-command-returns-integer-for-valid-input"
    (let ((result (nerimux/terminal/parser::%parse-osc-command "52;data" 2)))
      (expect (= 52 result))))


  (it "handle-osc-52-no-inner-semicolon-is-noop"
    (let* ((received :not-called)
           (nerimux/terminal/parser:*osc52-handler*
             (lambda (text) (setf received text))))
      (finishes (nerimux/terminal/parser::%handle-osc-52 "nodatahere"))
      (expect (eq :not-called received)))))

(describe "parser-suite/csi-colon-subparams"

  (it "csi-colon-undercurl-keeps-leading-underline"
    (with-screen (s 8 2)
      (feed s (esc "[4:3m"))            ; undercurl via colon sub-parameter
      (feed s "X")
      (expect (char= #\X (char-at s 0 0)))
      (expect (logbitp 3 (attrs-at s 0 0)))))

  (it "csi-colon-multi-param-mixed"
    (with-screen (s 8 2)
      (feed s (esc "[0;4:3;1m"))
      (feed s "Y")
      (expect (char= #\Y (char-at s 0 0)))
      (expect (logbitp 3 (attrs-at s 0 0)))
      (expect (logbitp 0 (attrs-at s 0 0)))))

  (it "csi-colon-truecolor-form-does-not-abort"
    (with-screen (s 8 2)
      (feed s (esc "[38:2::255:0:0m"))
      (feed s "Z")
      (expect (char= #\Z (char-at s 0 0))))))

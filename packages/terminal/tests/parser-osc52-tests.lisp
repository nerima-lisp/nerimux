(in-package #:nerimux/test/terminal)

(describe "terminal-suite/osc52-coverage"

  (it "osc52-handler-invoked-with-decoded-text"
    (with-screen (s 20 5)
      (let* ((received nil)
             (nerimux/terminal/parser:*osc52-handler*
               (lambda (text) (setf received text))))
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]52;c;aGVsbG8=~C" #\Escape (code-char 7))
            :encoding :utf-8))
        (expect (string= "hello" received)))))

  (it "osc52-nil-handler-silently-dropped"
    (with-screen (s 20 5)
      (let ((nerimux/terminal/parser:*osc52-handler* nil))
        (finishes
          (screen-process-bytes s
            (cl-codec-kit:string-to-octets
              (format nil "~C]52;c;SGVsbG8=~C" #\Escape (code-char 7))
              :encoding :utf-8))))))

  (it "osc52-read-request-silently-ignored"
    (with-screen (s 20 5)
      (let* ((received :not-called)
             (nerimux/terminal/parser:*osc52-handler*
               (lambda (text) (setf received text))))
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]52;c;?~C" #\Escape (code-char 7))
            :encoding :utf-8))
        (expect (eq :not-called received)))))

  (it "osc52-invalid-utf8-payload-is-dropped"
    (let* ((received :not-called)
           (nerimux/terminal/parser:*osc52-handler*
             (lambda (text) (setf received text))))
      (finishes
        (nerimux/terminal/parser::%handle-osc-52 "c;7aCA"))
      (expect (eq :not-called received))))


  (it "osc52-clipboard-sequence-round-trips-through-base64-decode"
    (let* ((text   "hello, nerimux!")
           (seq    (nerimux/terminal/parser:osc52-clipboard-sequence text))
           (prefix (format nil "~C]52;c;" #\Escape)))
      (expect (string= prefix (subseq seq 0 (length prefix))))
      (expect (string= (format nil "~C\\" #\Escape) (subseq seq (- (length seq) 2))))
      (let* ((payload (subseq seq (length prefix) (- (length seq) 2)))
             (decoded (cl-codec-kit:octets-to-string
                       (nerimux/terminal/parser::%base64-decode payload)
                       :encoding :utf-8)))
        (expect (string= text decoded)))))

  (it "osc52-inbound-passthrough-enqueues-on-the-screen"
    (with-screen (s 20 5)
      (nerimux/terminal/parser::%osc52-inbound-passthrough s "from pane")
      (expect (equal (list (nerimux/terminal/parser:osc52-clipboard-sequence
                            "from pane"))
                     (nerimux/terminal/types:screen-clipboard-queue s)))))

  (it "initialize-osc52-handler-restores-the-passthrough-function"
    (let ((nerimux/terminal/parser:*osc52-handler* nil))
      (nerimux/terminal/parser::initialize-osc52-handler)
      (expect (eq #'nerimux/terminal/parser::%osc52-inbound-passthrough
                  nerimux/terminal/parser:*osc52-handler*)))))

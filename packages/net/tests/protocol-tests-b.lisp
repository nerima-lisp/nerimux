(in-package #:nerimux/test/net)

(describe "protocol-suite"


  (it "read-u32-decodes-big-endian"
    (let ((buffer (make-array 8 :element-type '(unsigned-byte 8)
                                :initial-contents '(0 0 0 0 0 0 1 0))))
      (expect (= 0      (nerimux/protocol:read-u32 buffer 0)))
      (expect (= 256    (nerimux/protocol:read-u32 buffer 4)))
      (let ((buf2 (nerimux/protocol:u32-octets #xDEADBEEF)))
        (expect (= #xDEADBEEF (nerimux/protocol:read-u32 buf2 0))))))


  (it "split-on-nul-bytes-empty-input-returns-empty-list"
    (expect (null (nerimux/protocol:split-on-nul-bytes #()))))

  (it "split-on-nul-bytes-single-field"
    (let* ((bytes (cl-codec-kit:string-to-octets "hello" :encoding :utf-8))
           (buf   (concatenate '(simple-array (unsigned-byte 8) (*)) bytes #(0))))
      (expect (equal '("hello") (nerimux/protocol:split-on-nul-bytes buf)))))

  (it "split-on-nul-bytes-multiple-fields"
    (let* ((a (cl-codec-kit:string-to-octets "alpha" :encoding :utf-8))
           (b (cl-codec-kit:string-to-octets "beta"  :encoding :utf-8))
           (c (cl-codec-kit:string-to-octets "gamma" :encoding :utf-8))
           (buf (concatenate '(simple-array (unsigned-byte 8) (*))
                             a #(0) b #(0) c #(0))))
      (expect (equal '("alpha" "beta" "gamma")
                     (nerimux/protocol:split-on-nul-bytes buf)))))

  (it "split-on-nul-bytes-no-nul-returns-empty-list"
    (let ((buf (cl-codec-kit:string-to-octets "no-nul" :encoding :utf-8)))
      (expect (null (nerimux/protocol:split-on-nul-bytes buf)))))


  (it "command-name-to-string-table"
    (dolist (c '((:new-window  "new-window"  "lowercase keyword → downcased")
                 (:NEW-WINDOW  "new-window"  "uppercase keyword → downcased")
                 (:SELECT-PANE "select-pane" "uppercase keyword → downcased")
                 ("select-pane" "select-pane" "string → pass through")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (string= expected (nerimux/protocol:command-name-to-string input))))))


  (it "assemble-command-fields-table"
    (dolist (c '(("new-window"  nil    nil          ("new-window")               "name only")
                 ("select-pane" "$1:0" nil          ("$1:0" "select-pane")       "target + name")
                 ("send-keys"   nil    ("C-c" "")   ("send-keys" "C-c" "")       "name + args")
                 ("resize-pane" "2:0"  ("-U" "5")   ("2:0" "resize-pane" "-U" "5") "target + name + args")))
      (destructuring-bind (name target args expected desc) c
        (declare (ignore desc))
        (expect (equal expected (nerimux/protocol:assemble-command-fields name target args))))))


  (it "encode-fields-to-buffer-empty-fields-produces-empty-buffer"
    (let ((buf (nerimux/protocol:encode-fields-to-buffer '())))
      (expect (= 0 (length buf)))))

  (it "encode-fields-to-buffer-single-field-has-trailing-nul"
    (let* ((field-bytes (cl-codec-kit:string-to-octets "hello" :encoding :utf-8))
           (buf (nerimux/protocol:encode-fields-to-buffer (list field-bytes))))
      (expect (= 6 (length buf)))
      (expect (= 0 (aref buf 5)))))

  (it "encode-fields-to-buffer-multiple-fields-split-by-nuls"
    (let* ((f1  (cl-codec-kit:string-to-octets "ab" :encoding :utf-8))
           (f2  (cl-codec-kit:string-to-octets "cd" :encoding :utf-8))
           (buf (nerimux/protocol:encode-fields-to-buffer (list f1 f2))))
      (expect (= 6 (length buf)))
      (expect (= 0 (aref buf 2)))
      (expect (= 0 (aref buf 5)))))


  (it "to-octets-coerces-list-to-simple-vector"
    (let ((result (to-octets '(1 2 3))))
      (expect (typep result '(simple-array (unsigned-byte 8) (*))))
      (expect (equalp #(1 2 3) result))))

  (it "to-octets-idempotent-on-simple-vector"
    (let* ((original #(10 20 30))
           (result   (to-octets original)))
      (expect (equalp original result))))


  (it "decode-size-zero-rows-zero-cols"
    (multiple-value-bind (rows cols) (decode-size (u16-octets-pair 0 0))
      (expect (= 0 rows))
      (expect (= 0 cols))))

  (it "decode-size-max-u16-values"
    (multiple-value-bind (rows cols) (decode-size (u16-octets-pair 65535 65535))
      (expect (= 65535 rows))
      (expect (= 65535 cols))))

  (it "decode-text-empty-payload"
    (expect (string= "" (decode-text #()))))

  (it "decode-text-ascii"
    (let ((bytes (cl-codec-kit:string-to-octets "hello" :encoding :utf-8)))
      (expect (string= "hello" (decode-text bytes)))))


  (it "decode-command-payload-empty-payload-returns-nil-values"
    (multiple-value-bind (command target args)
        (decode-command-payload #())
      (expect (null command))
      (expect (null target))
      (expect (null args))))

  (it "decode-command-payload-no-nul-byte-returns-nil-values"
    (let ((payload (cl-codec-kit:string-to-octets "no-nul-here" :encoding :utf-8)))
      (multiple-value-bind (command target args)
          (decode-command-payload payload)
        (expect (null command))
        (expect (null target))
        (expect (null args)))))


  (it "msg-command-empty-args-list-roundtrips"
    (let ((frame-nil  (msg-command :new-window nil nil))
          (frame-list (msg-command :new-window nil '())))
      (expect (equalp frame-nil frame-list))))

  (it "msg-command-string-command-name-roundtrips"
    (let ((frame (msg-command "split-window" nil nil)))
      (multiple-value-bind (type payload) (decode-frame frame)
        (expect (= +msg-command+ type))
        (multiple-value-bind (command target args)
            (decode-command-payload payload)
          (expect (eq :split-window command))
          (expect (null target))
          (expect (null args))))))


  (it "to-octets-empty-list-produces-empty-vector"
    (let ((result (to-octets '())))
      (expect (typep result '(simple-array (unsigned-byte 8) (*))))
      (expect (= 0 (length result)))))


  (it "split-on-nul-bytes-trailing-bytes-after-last-nul-are-ignored"
    (let* ((a     (cl-codec-kit:string-to-octets "alpha" :encoding :utf-8))
           (b     (cl-codec-kit:string-to-octets "beta"  :encoding :utf-8))
           (buf   (concatenate '(simple-array (unsigned-byte 8) (*))
                               a #(0) b)))
      (expect (equal '("alpha")
                     (nerimux/protocol:split-on-nul-bytes buf)))))


  (it "assemble-command-fields-preserves-multiple-args-order"
    (expect (equal '("cmd" "a" "b" "c" "d")
                   (nerimux/protocol:assemble-command-fields "cmd" nil '("a" "b" "c" "d")))))


  (it "encode-fields-to-buffer-and-split-on-nul-bytes-are-symmetric"
    (let* ((strings  '("alpha" "beta" "gamma" "delta"))
           (octets   (mapcar (lambda (s)
                               (cl-codec-kit:string-to-octets s :encoding :utf-8))
                             strings))
           (buf      (nerimux/protocol:encode-fields-to-buffer octets))
           (decoded  (nerimux/protocol:split-on-nul-bytes buf)))
      (expect (equal strings decoded)))))

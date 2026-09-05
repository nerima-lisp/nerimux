(in-package #:nerimux/test/terminal)

(describe "terminal-suite/utf8"

  (it "utf8-byte-classification-and-lead-decoding"
    (expect (nerimux/terminal/parser::utf8-lead-p #xC0))
    (expect (nerimux/terminal/parser::utf8-lead-p #xFE))
    (expect (not (nerimux/terminal/parser::utf8-lead-p #xFF)))
    (expect (not (nerimux/terminal/parser::utf8-lead-p #x7F)))
    (expect (nerimux/terminal/parser::utf8-continuation-p #x80))
    (expect (nerimux/terminal/parser::utf8-continuation-p #xBF))
    (expect (not (nerimux/terminal/parser::utf8-continuation-p #xC0)))
    (multiple-value-bind (accumulator remaining)
        (nerimux/terminal/parser::utf8-lead-decode #xC2)
      (expect (= 2 accumulator))
      (expect (= 1 remaining)))
    (multiple-value-bind (accumulator remaining)
        (nerimux/terminal/parser::utf8-lead-decode #xE3)
      (expect (= #x03 accumulator))
      (expect (= 2 remaining)))
    (multiple-value-bind (accumulator remaining)
        (nerimux/terminal/parser::utf8-lead-decode #xF0)
      (expect (= 0 accumulator))
      (expect (= 3 remaining))))

  (it "utf8-multibyte-table"
    (dolist (row '((#\é "2-byte: U+00E9 é")
                   (#\あ "3-byte: U+3042 あ")))
      (destructuring-bind (char desc) row
        (declare (ignore desc))
        (with-screen (s 10 2)
          (utf8-feed s (string char))
          (expect (char= char (char-at s 0 0)))))))

  (it "utf8-4byte"
    (when (< #x1F600 char-code-limit)
      (with-screen (s 10 2)
        (screen-process-bytes s (make-array 4 :element-type '(unsigned-byte 8)
                                              :initial-contents '(#xF0 #x9F #x98 #x80)))
        (expect (char= (code-char #x1F600) (char-at s 0 0))))))

  (it "utf8-split"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xE3)))
      (screen-process-bytes s (make-array 2 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#x81 #x82)))
      (expect (char= #\あ (char-at s 0 0)))))

  (it "utf8-mixed"
    (with-screen (s 10 2)
      (utf8-feed s "aあb")
      (expect (char= #\a  (char-at s 0 0)))
      (expect (char= #\あ (char-at s 1 0)))
      (expect (= 2 (cell-width (cell-at s 1 0))))
      (expect (= 0 (cell-width (cell-at s 2 0))))
      (expect (char= #\b  (char-at s 3 0)))))

  (it "utf8-box-drawing"
    (with-screen (s 10 2)
      (utf8-feed s "│─")
      (expect (char= #\│ (char-at s 0 0)))
      (expect (char= #\─ (char-at s 1 0)))))

  (it "utf8-malformed"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xFF)))
      (expect (char= (code-char #xFFFD) (char-at s 0 0)))))


  (it "utf8-cesu8-lone-surrogate-becomes-replacement"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 3 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xED #xA0 #x80)))
      (let ((written (char-at s 0 0)))
        (expect (char= (code-char #xFFFD) written))
        (expect (cl-codec-kit:string-to-octets (string written) :encoding :utf-8)
                :to-be-truthy))))

  (it "utf8-cesu8-low-surrogate-becomes-replacement"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 3 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xED #xBF #xBF)))
      (expect (char= (code-char #xFFFD) (char-at s 0 0))))))

(describe "terminal-suite/cell-primitives"
          (it "blank-cell-returns-an-independent-default-cell"
              (let ((first (nerimux/terminal/types:blank-cell))
                    (second (nerimux/terminal/types:blank-cell)))
                (setf (nerimux/terminal/types:cell-char first) #\X)
                (expect
                 (char= #\Space (nerimux/terminal/types:cell-char second)))))
          (it "clamp-bounds-values-at-either-end"
              (expect (= 0 (nerimux/terminal/types:clamp -1 0 10)))
              (expect (= 5 (nerimux/terminal/types:clamp 5 0 10)))
              (expect (= 10 (nerimux/terminal/types:clamp 11 0 10))))
          (it "safe-code-char-replaces-invalid-code-points"
              (expect
               (char= #\A
                      (nerimux/terminal/types:safe-code-char (char-code #\A))))
              (expect
               (char= (code-char #xFFFD)
                      (nerimux/terminal/types:safe-code-char #xD800)))
              (expect
               (char= (code-char #xFFFD)
                      (nerimux/terminal/types:safe-code-char char-code-limit))))
          (it "surrogate-code-point-p-covers-range-boundaries"
              (expect
               (not (nerimux/terminal/types::surrogate-code-point-p #xD7FF)))
              (expect (nerimux/terminal/types::surrogate-code-point-p #xD800))
              (expect (nerimux/terminal/types::surrogate-code-point-p #xDFFF))
              (expect
               (not (nerimux/terminal/types::surrogate-code-point-p #xE000))))
          (it "char-width-delegates-unicode-width"
              (expect
               (= 0 (nerimux/terminal/types:char-width (code-char #x0301))))
              (expect (= 2 (nerimux/terminal/types:char-width #\あ)))
              (expect (= 1 (nerimux/terminal/types:char-width #\A)))))

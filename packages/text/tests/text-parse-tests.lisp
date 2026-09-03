(in-package #:nerimux/test/text)

(describe "text-parse-suite"


  (it "non-empty-string-table"
    (dolist (row '(("hello" "hello" "non-empty-string of \"hello\" must return itself")
                   (""      nil     "non-empty-string of empty string must return NIL")
                   (nil     nil     "non-empty-string of NIL input must return NIL")
                   (42      nil     "non-empty-string of non-string input must return NIL")))
      (destructuring-bind (input expected desc) row
        (declare (ignore desc))
        (expect (equal expected (nerimux/text:non-empty-string input))))))


  (it "parse-integer-or-nil-table"
    (dolist (row '(("0"    0   nil                         "zero parses")
                   ("42"   42  nil                         "multi-digit parses")
                   ("-7"   -7  nil                         "signed integers parse")
                   ("1f"   31  (:radix 16)                "hexadecimal parsing works")
                   ("123x" 123 (:end 3)                   "substring parsing works")
                   ("abc"  nil nil                        "alphabetic input returns NIL")
                   (""     nil nil                        "empty string returns NIL")
                   (nil    nil nil                        "NIL input returns NIL")))
      (destructuring-bind (input expected args desc) row
        (declare (ignore desc))
        (expect (eql expected (apply #'nerimux/text:parse-integer-or-nil input args))))))

  (it "parse-integer-or-nil-returns-nil-for-non-integer-string"
    (dolist (bad '("" "abc" "1.5" "12abc" " "))
      (expect (null (nerimux/text:parse-integer-or-nil bad)))))

  (it "parse-integer-or-nil-returns-nil-for-nil-input"
    (expect (null (nerimux/text:parse-integer-or-nil nil))))

  (it "parse-integer-or-nil-returns-nil-for-parse-integer-type-error"
    (expect (null (nerimux/text:parse-integer-or-nil "1" :start "not-an-index"))))

  (it "parse-integer-or-nil-parses-valid-integer"
    (dolist (pair '(("0" 0) ("42" 42) ("-3" -3)))
      (destructuring-bind (str expected) pair
        (expect (= expected (nerimux/text:parse-integer-or-nil str)))))))

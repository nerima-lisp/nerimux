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


  (it "strip-dot-git-suffix-table"
    (dolist (row '(("repo.GIT" "repo" "case-insensitive .GIT is stripped")
                   ("repo.git" "repo" "lowercase .git is stripped")
                   ("repo"     "repo" "no suffix is unchanged")
                   (".git"     ".git" "bare .git is not stripped to empty")))
      (destructuring-bind (input expected desc) row
        (declare (ignore desc))
        (expect (string= expected (nerimux/text:strip-dot-git-suffix input))))))

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

(describe "shared control character classification"
  (it "classifies C0, DEL, C1, and bidi formatting controls"
    (dolist (code
             (append
              (loop for code from 0 to 31 collect code)
              (list 127)
              (loop for code from 128 to 159 collect code)
              (list #x061c #x200e #x200f)
              (loop for code from #x202a to #x202e collect code)
              (loop for code from #x2066 to #x2069 collect code)))
      (expect (nerimux/text:control-character-p (code-char code))))
    (dolist (code (list 32 126 160 #x200d #x2020 #x2065))
      (expect (not (nerimux/text:control-character-p (code-char code)))))))
